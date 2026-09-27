import Foundation
import os

/// Drives an app's own volume (and OneMix's mute, sent as volume 0) via AppleScript (see `NativeVolumeApps`). Apple Events
/// can block, so they run on a serial background queue; while a slider is dragging, only
/// the latest value per app is sent.
public final class ScriptedVolume: @unchecked Sendable {
    /// Unchecked: the descriptor is created once by the runner and only read afterwards.
    public struct ScriptResult: @unchecked Sendable {
        public let descriptor: NSAppleEventDescriptor?
        /// AppleScript error number, or nil on success (-1743: not permitted to send Apple Events).
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
    /// Bumped on every `set`, so a read that started before a set can be discarded.
    private var generation: [String: Int] = [:]  // guarded by lock
    private var lastSetting: [String: AppVolumeSetting] = [:]  // guarded by lock
    private var lastSend: [String: Date] = [:]  // touched only on queue

    /// Correction attempts after the final value of a change.
    private static let maxVerifyAttempts = 3

    /// - Parameters:
    ///   - isRunning: Checked right before each Apple Event is sent; sending one to an app
    ///     that isn't running would launch it.
    ///   - onResult: Called on the main actor after each `set` with whether it succeeded.
    /// - Parameters:
    ///   - minSendInterval: Minimum spacing between volume commands to one app. Music applies
    ///     `sound volume` asynchronously, and commands ~16 ms apart (a slider drag) can land
    ///     out of order, leaving it at a stale mid-drag value.
    ///   - verifyDelay: After the last change, how long to wait before reading the app's volume
    ///     back and re-sending if it doesn't match.
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

    /// Runs on `queue`.
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

    /// After the final value of a change, reads the app's volume back and re-sends it if the
    /// app ended somewhere else. Skipped as soon as a newer value is set.
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

    /// Reads the app's current `sound volume` (0...100, e.g. changed inside the app itself).
    /// The completion runs on the main actor, and is skipped if a `set` happened after this
    /// read started, so a stale value never overwrites a just-dragged one.
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

    /// Asks the app whether it is playing right now (used once, e.g. when OneMix launches
    /// while Music is already playing; after that its playerInfo notifications are enough).
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
