import Foundation
import os

/// Sets an app's volume through AppleScript (see `NativeVolumeApps`). Apple Events can
/// block, so they are sent from a serial queue, and rapid updates are coalesced per app.
public final class ScriptedVolume: @unchecked Sendable {
    /// Unchecked: the descriptor is never mutated after creation.
    public struct ScriptResult: @unchecked Sendable {
        public let descriptor: NSAppleEventDescriptor?
        /// AppleScript error number, or nil on success. -1743 means Apple Events are not permitted.
        public let errorNumber: Int?

        public init(descriptor: NSAppleEventDescriptor?, errorNumber: Int?) {
            self.descriptor = descriptor
            self.errorNumber = errorNumber
        }
    }

    private let queue: DispatchQueue
    private let minSendInterval: TimeInterval
    private let verifyDelay: TimeInterval
    private let isRunning: @Sendable (String) -> Bool
    private let run: @Sendable (String) -> ScriptResult
    private let onResult: @MainActor (String, Bool) -> Void

    private let lock = NSLock()
    private var pending: [String: AppVolumeSetting] = [:]  // guarded by lock
    /// Incremented on every `set` so that reads started earlier can be discarded.
    private var generation: [String: Int] = [:]  // guarded by lock
    private var lastSetting: [String: AppVolumeSetting] = [:]  // guarded by lock
    private var lastSend: [String: Date] = [:]  // confined to queue

    /// Maximum re-sends when the read-back volume doesn't match.
    private static let maxVerifyAttempts = 3

    /// - Parameters:
    ///   - minSendInterval: Minimum spacing between commands to one app. Music applies
    ///     `sound volume` asynchronously, and closely spaced commands can land out of order.
    ///   - verifyDelay: Delay after the last change before reading the volume back.
    ///   - isRunning: Checked before each Apple Event, since sending one launches the app.
    ///   - onResult: Called on the main actor after each send with whether it succeeded.
    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.onemix.scripted-volume", qos: .userInitiated),
        minSendInterval: TimeInterval = 0.08,
        verifyDelay: TimeInterval = 0.3,
        isRunning: @escaping @Sendable (String) -> Bool,
        run: @escaping @Sendable (String) -> ScriptResult = ScriptedVolume.runAppleScript,
        onResult: @escaping @MainActor (String, Bool) -> Void
    ) {
        self.queue = queue
        self.minSendInterval = minSendInterval
        self.verifyDelay = verifyDelay
        self.isRunning = isRunning
        self.run = run
        self.onResult = onResult
    }

    public func set(_ setting: AppVolumeSetting, for bundleID: String) {
        let alreadyQueued: Bool = lock.withLock {
            generation[bundleID, default: 0] += 1
            lastSetting[bundleID] = setting
            defer { pending[bundleID] = setting }
            return pending[bundleID] != nil
        }
        guard !alreadyQueued else { return }
        queue.async { [self] in
            // Waiting here (on this app's serial queue) lets further drag values coalesce.
            if let last = lastSend[bundleID] {
                let wait = minSendInterval - Date().timeIntervalSince(last)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            guard let latest = lock.withLock({ pending.removeValue(forKey: bundleID) }) else { return }
            let sentGeneration = lock.withLock { generation[bundleID, default: 0] }
            send(NativeVolumeApps.scriptVolume(for: latest), to: bundleID)
            scheduleVerify(bundleID, generation: sentGeneration, attempt: 1)
        }
    }

    /// Must be called on `queue`.
    @discardableResult
    private func send(_ volume: Int, to bundleID: String) -> Bool {
        guard isRunning(bundleID) else {
            Self.log.info("Skipped \(bundleID, privacy: .public) volume \(volume): not running")
            return false
        }
        let result = run("tell application id \"\(bundleID)\" to set sound volume to \(volume)")
        lastSend[bundleID] = Date()
        let succeeded = result.errorNumber == nil
        Self.log.info("Sent \(bundleID, privacy: .public) volume \(volume): \(succeeded ? "ok" : "failed \(result.errorNumber ?? 0)", privacy: .public)")
        Task { @MainActor [onResult] in onResult(bundleID, succeeded) }
        return succeeded
    }

    /// Reads the volume back after a change settles and re-sends it on mismatch. Abandoned
    /// if a newer value is set.
    private func scheduleVerify(_ bundleID: String, generation sentGeneration: Int, attempt: Int) {
        queue.asyncAfter(deadline: .now() + verifyDelay) { [self] in
            let (current, expected): (Int, AppVolumeSetting?) = lock.withLock {
                (generation[bundleID, default: 0], lastSetting[bundleID])
            }
            guard current == sentGeneration, let expected, isRunning(bundleID),
                  let actual = run("tell application id \"\(bundleID)\" to get sound volume").descriptor?.int32Value
            else { return }
            let wanted = NativeVolumeApps.scriptVolume(for: expected)
            guard Int(actual) != wanted else { return }
            Self.log.info("\(bundleID, privacy: .public) ended at volume \(actual) instead of \(wanted); re-sending (attempt \(attempt))")
            send(wanted, to: bundleID)
            if attempt < Self.maxVerifyAttempts {
                scheduleVerify(bundleID, generation: sentGeneration, attempt: attempt + 1)
            }
        }
    }

    /// Reads the app's current `sound volume` (0...100). The completion runs on the main
    /// actor and is dropped if a `set` happens while the read is in flight.
    public func read(_ bundleID: String, completion: @escaping @MainActor (Int) -> Void) {
        let startGeneration = lock.withLock { generation[bundleID, default: 0] }
        queue.async { [self] in
            guard isRunning(bundleID),
                  let volume = run("tell application id \"\(bundleID)\" to get sound volume").descriptor?.int32Value
            else { return }
            Task { @MainActor [self] in
                guard self.lock.withLock({ self.generation[bundleID, default: 0] }) == startGeneration else { return }
                completion(Int(volume))
            }
        }
    }

    /// Queries the current player state. Only needed at launch; playerInfo notifications
    /// cover changes after that.
    public func readIsPlaying(_ bundleID: String, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async { [self] in
            guard isRunning(bundleID),
                  let state = run("tell application id \"\(bundleID)\" to (player state as text)").descriptor?.stringValue
            else { return }
            Task { @MainActor in completion(state == "playing") }
        }
    }

    private static let log = Logger(subsystem: "com.onemix.OneMix", category: "scripted-volume")

    public static let runAppleScript: @Sendable (String) -> ScriptResult = { source in
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let errorNumber = error.map { ($0[NSAppleScript.errorNumber] as? Int) ?? -1 }
        if let error {
            Logger(subsystem: "com.onemix.OneMix", category: "scripted-volume")
                .error("AppleScript failed: \(error, privacy: .public)")
        }
        return ScriptResult(descriptor: descriptor, errorNumber: errorNumber)
    }
}
