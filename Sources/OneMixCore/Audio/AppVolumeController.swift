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

/// Owns one ProcessTap per app that needs one. Apps at 100% and unmuted get no tap,
/// unless they were already routed this session: returning to 100% keeps the tap at
/// full gain, since tearing it down (and later rebuilding it) causes an audible gap.
@MainActor @Observable
public final class AppVolumeController {
    public private(set) var failedBundleIDs: Set<String> = []

    @ObservationIgnored private var taps: [String: any AudioTap] = [:]
    @ObservationIgnored private var targets: [String: TapTarget] = [:]
    @ObservationIgnored private var outputUID: String?
    /// Apps that have had a tap this session; they keep one even at 100% until they
    /// leave `sync`'s targets (app quit / no audio processes) or `removeAll`.
    @ObservationIgnored private var routed: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.onemix.OneMix", category: "taps")
    /// `startGain` is the gain the new tap ramps from: 1 (native level) for an app's
    /// first tap, or the target gain when replacing an existing tap.
    typealias TapFactory = (_ processObjectIDs: [AudioObjectID], _ outputUID: String, _ gain: Float, _ startGain: Float) throws -> any AudioTap
    @ObservationIgnored private let makeTap: TapFactory

    public init() {
        makeTap = { processObjectIDs, outputUID, gain, startGain in
            try ProcessTap(processObjectIDs: processObjectIDs, outputUID: outputUID, gain: gain, startGain: startGain)
        }
    }

    /// Test seam: lets tests substitute a fake tap instead of a real `ProcessTap`.
    init(makeTap: @escaping TapFactory) {
        self.makeTap = makeTap
    }

    public var activeTapCount: Int { taps.count }

    /// Points every tap at the new output device: moved in place for a different device,
    /// rebuilt for the same UID (it can point at a new, live device after a Bluetooth
    /// reconnect, while the old aggregate has gone away silently).
    public func setOutputDevice(uid: String) {
        outputUID = uid
        failedBundleIDs = []
        for target in targets.values {
            // A different device: move the running tap in place (restarting its IO makes
            // Bluetooth smart routing hijack the output back to in-ear AirPods). The same
            // UID (e.g. AirPods reconnecting) still gets a full rebuild, since the old
            // aggregate may be dead.
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

    /// Makes the set of taps match `newTargets`; apps not listed lose their tap.
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

    /// Clears `failedBundleIDs` and re-applies every current target, so a transient
    /// failure (e.g. before Screen & System Audio Recording permission is granted)
    /// isn't stuck forever. Callers (e.g. the panel opening, or permission becoming
    /// granted) decide when this is worth trying again.
    public func retryFailed() {
        failedBundleIDs = []
        for target in targets.values { apply(target) }
    }

    /// Tears down and rebuilds every tap from the current targets, e.g. once capture
    /// permission newly becomes granted. Unlike `apply`, this always rebuilds even when
    /// nothing about the target changed.
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

    /// Decides whether `target`'s tap needs (re)building and, if so, rebuilds it.
    /// `force` skips the "unchanged" and "already failed" shortcuts, for callers that
    /// need every tap actually recreated.
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
        // Don't hammer Core Audio retrying a failed tap on every slider tick.
        if !force, failedBundleIDs.contains(target.bundleID), previous?.processObjectIDs == target.processObjectIDs {
            return
        }
        rebuildTap(for: target, outputUID: outputUID)
    }

    /// Builds the replacement tap before invalidating the old one, so a muted or
    /// quieted app never briefly plays at full native volume during a rebuild. If
    /// construction fails, the old tap is still invalidated so the app isn't left
    /// stuck muted with nothing replaying its audio.
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
