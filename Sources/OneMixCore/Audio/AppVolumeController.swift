import CoreAudio
import Observation
import os

public struct TapTarget: Equatable, Sendable {
    public let bundleID: String
    public let processObjectIDs: [AudioObjectID]
    public let setting: AppVolumeSetting

    public init(bundleID: String, processObjectIDs: [AudioObjectID], setting: AppVolumeSetting) {
        self.bundleID = bundleID
        self.processObjectIDs = processObjectIDs
        self.setting = setting
    }
}

/// Manages a process tap per app. Unmuted apps at 100% are left untapped, except those
/// already routed this session: they keep their tap at unity gain, because tearing it down
/// causes an audible gap.
@MainActor @Observable
public final class AppVolumeController {
    public private(set) var failedBundleIDs: Set<String> = []

    @ObservationIgnored private var taps: [String: any AudioTap] = [:]
    @ObservationIgnored private var targets: [String: TapTarget] = [:]
    @ObservationIgnored private var outputUID: String?
    /// Apps tapped this session. Cleared when an app leaves `sync`'s targets or on `removeAll`.
    @ObservationIgnored private var routed: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.onemix.OneMix", category: "taps")
    /// `startGain` is 1 for an app's first tap and the target gain for a replacement.
    typealias TapFactory = (_ processObjectIDs: [AudioObjectID], _ outputUID: String, _ gain: Float, _ startGain: Float) throws -> any AudioTap
    @ObservationIgnored private let makeTap: TapFactory

    public init() {
        makeTap = { processObjectIDs, outputUID, gain, startGain in
            try ProcessTap(processObjectIDs: processObjectIDs, outputUID: outputUID, gain: gain, startGain: startGain)
        }
    }

    init(makeTap: @escaping TapFactory) {
        self.makeTap = makeTap
    }

    public var activeTapCount: Int { taps.count }

    /// Retargets all taps to `uid`. A different device is swapped in place. The same UID is
    /// rebuilt, since after a Bluetooth reconnect the old aggregate may be silently dead.
    public func setOutputDevice(uid: String) {
        outputUID = uid
        failedBundleIDs = []
        for target in targets.values {
            if let tap = taps[target.bundleID], tap.outputUID != uid {
                do {
                    try tap.retarget(outputUID: uid)
                    log.info("Moved tap for \(target.bundleID, privacy: .public) to \(uid, privacy: .public)")
                    reconcile(target, previous: target, force: false)
                    continue
                } catch {
                    log.error("Moving tap for \(target.bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            reconcile(target, previous: nil, force: true)
        }
    }

    /// Reconciles taps with `newTargets`, removing taps for apps not listed.
    public func sync(_ newTargets: [TapTarget]) {
        let wanted = Set(newTargets.map(\.bundleID))
        for bundleID in Array(targets.keys) where !wanted.contains(bundleID) {
            targets[bundleID] = nil
            routed.remove(bundleID)
            tearDown(bundleID)
            failedBundleIDs.remove(bundleID)
        }
        for target in newTargets { apply(target) }
    }

    public func apply(_ target: TapTarget) {
        let previous = targets[target.bundleID]
        targets[target.bundleID] = target
        reconcile(target, previous: previous, force: false)
    }

    /// Clears `failedBundleIDs` and re-applies all targets, so failures that happened
    /// before a permission was granted can recover.
    public func retryFailed() {
        failedBundleIDs = []
        for target in targets.values { apply(target) }
    }

    /// Rebuilds every tap unconditionally, e.g. after capture permission is granted.
    public func rebuildAll() {
        failedBundleIDs = []
        for target in targets.values { reconcile(target, previous: nil, force: true) }
    }

    public func removeAll() {
        for tap in taps.values { tap.invalidate() }
        taps = [:]
        targets = [:]
        routed = []
        failedBundleIDs = []
    }

    /// Rebuilds `target`'s tap if it changed. `force` also rebuilds unchanged and failed taps.
    private func reconcile(_ target: TapTarget, previous: TapTarget?, force: Bool) {
        let wantsTap = target.setting.needsTap || routed.contains(target.bundleID)
        guard wantsTap, !target.processObjectIDs.isEmpty, let outputUID else {
            tearDown(target.bundleID)
            failedBundleIDs.remove(target.bundleID)
            return
        }
        if !force, let tap = taps[target.bundleID], tap.processObjectIDs == target.processObjectIDs, tap.outputUID == outputUID {
            tap.setGain(target.setting.effectiveGain)
            return
        }
        // Failed taps wait for `retryFailed` rather than retrying on every update.
        if !force, failedBundleIDs.contains(target.bundleID), previous?.processObjectIDs == target.processObjectIDs {
            return
        }
        rebuildTap(for: target, outputUID: outputUID)
    }

    /// Creates the new tap before invalidating the old one, so the app never briefly plays
    /// at native volume. The old tap is invalidated even on failure, since leaving it would
    /// keep the app muted with nothing replaying it.
    private func rebuildTap(for target: TapTarget, outputUID: String) {
        let oldTap = taps[target.bundleID]
        log.info("Building tap for \(target.bundleID, privacy: .public) on \(outputUID, privacy: .public)")
        do {
            let gain = target.setting.effectiveGain
            let newTap = try makeTap(target.processObjectIDs, outputUID, gain, oldTap == nil ? 1 : gain)
            taps[target.bundleID] = newTap
            routed.insert(target.bundleID)
            oldTap?.invalidate()
            failedBundleIDs.remove(target.bundleID)
        } catch {
            oldTap?.invalidate()
            taps.removeValue(forKey: target.bundleID)
            log.error("Tap for \(target.bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            failedBundleIDs.insert(target.bundleID)
        }
    }

    private func tearDown(_ bundleID: String) {
        guard let tap = taps.removeValue(forKey: bundleID) else { return }
        log.info("Removing tap for \(bundleID, privacy: .public)")
        tap.invalidate()
    }
}
