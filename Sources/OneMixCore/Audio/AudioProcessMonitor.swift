import CoreAudio
import Darwin
import Observation
import os

/// A Core Audio process object: any process that has touched audio.
public struct AudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

/// Live list of Core Audio process objects. Updates via listeners on the process list and
/// on each process's "is running" flag, plus a cheap once-a-second re-check as a safety net.
///
/// Core Audio never posts change notifications for `kAudioProcessPropertyIsRunningOutput`
/// (only for `kAudioProcessPropertyIsRunning`), so listening to the output flag directly
/// missed apps starting playback until something unrelated triggered a refresh.
@MainActor @Observable
public final class AudioProcessMonitor {
    public private(set) var processes: [AudioProcess] = []

    @ObservationIgnored private var listListener: PropertyListener?
    @ObservationIgnored private var processListeners: [AudioObjectID: PropertyListener] = [:]
    @ObservationIgnored private var recheckTimer: Timer?

    private static let log = Logger(subsystem: "com.onemix.OneMix", category: "processes")
    private static let runningOutputAddress = CA.address(kAudioProcessPropertyIsRunningOutput)
    private static let runningAddress = CA.address(kAudioProcessPropertyIsRunning)

    public init() {
        refresh()
        listListener = PropertyListener(.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
        }
        // Safety net for changes no event covers (e.g. an app already running input that
        // starts output). A few property reads per process; publishes only on change.
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func refresh() {
        let ids = (try? CA.getObjectIDs(.system, CA.address(kAudioHardwarePropertyProcessObjectList))) ?? []
        // Listen before reading, so a change between the read and the registration isn't lost.
        syncListeners(ids)
        let ownPID = getpid()
        let updated = ids.compactMap(Self.read).filter { $0.pid != ownPID }
        if updated != processes {
            let before = Dictionary(processes.map { ($0.objectID, $0.isRunningOutput) }, uniquingKeysWith: { a, _ in a })
            for process in updated where before[process.objectID] != process.isRunningOutput {
                Self.log.info("Process \(process.objectID) \(process.bundleID ?? "?", privacy: .public) output=\(process.isRunningOutput)")
            }
            processes = updated
        }
    }

    private func syncListeners(_ ids: [AudioObjectID]) {
        let current = Set(ids)
        for id in processListeners.keys where !current.contains(id) {
            processListeners[id] = nil
        }
        for id in current where processListeners[id] == nil {
            processListeners[id] = PropertyListener(id, Self.runningAddress) { [weak self] in
                self?.refresh()
            }
        }
    }

    private static func read(_ id: AudioObjectID) -> AudioProcess? {
        guard let pid = try? CA.get(id, CA.address(kAudioProcessPropertyPID), initial: pid_t(-1)), pid > 0 else { return nil }
        let bundleID = try? CA.getString(id, CA.address(kAudioProcessPropertyBundleID))
        let running = (try? CA.get(id, runningOutputAddress, initial: UInt32(0))) ?? 0
        return AudioProcess(
            objectID: id,
            pid: pid,
            bundleID: bundleID?.isEmpty == false ? bundleID : nil,
            isRunningOutput: running != 0
        )
    }
}
