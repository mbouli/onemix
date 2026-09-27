import Foundation
import XCTest
@testable import OneMixCore

/// Thread-safe recorder for the fake AppleScript runner.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _running = true
    var scripts: [String] { lock.withLock { _scripts } }
    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    func record(_ script: String) { lock.withLock { _scripts.append(script) } }
}

@MainActor
final class ScriptedVolumeTests: XCTestCase {
    private let music = "com.apple.Music"

    private func makeVolume(
        _ recorder: Recorder,
        queue: DispatchQueue,
        result: @escaping @Sendable (String) -> ScriptedVolume.ScriptResult = { _ in .init(descriptor: nil, errorNumber: nil) },
        onResult: @escaping @MainActor (String, Bool) -> Void = { _, _ in }
    ) -> ScriptedVolume {
        ScriptedVolume(
            queue: queue,
            minSendInterval: 0,
            verifyDelay: 3600,  // these tests don't exercise read-back verification
            isRunning: { _ in recorder.running },
            run: { script in recorder.record(script); return result(script) },
            onResult: onResult
        )
    }

    private func settle(_ queue: DispatchQueue) async {
        queue.sync {}
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testRapidSetsCoalesceToLatestValue() async {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = makeVolume(recorder, queue: queue)
        queue.suspend()
        volume.set(AppVolumeSetting(volume: 0.2), for: music)
        volume.set(AppVolumeSetting(volume: 0.5), for: music)
        volume.set(AppVolumeSetting(volume: 0.7, muted: true), for: music)
        queue.resume()
        await settle(queue)
        XCTAssertEqual(recorder.scripts, ["tell application id \"com.apple.Music\" to set sound volume to 0"], "muted is sent as volume 0")
    }

    func testSetIsSkippedIfAppQuitBeforeItRuns() async {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = makeVolume(recorder, queue: queue)
        queue.suspend()
        volume.set(AppVolumeSetting(volume: 0.3), for: music)
        recorder.running = false  // user quits Music before the Apple Event is sent
        queue.resume()
        await settle(queue)
        XCTAssertEqual(recorder.scripts, [], "sending the event would relaunch the app")
    }

    func testReadIsDroppedIfASetHappensAfterIt() async {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = makeVolume(recorder, queue: queue, result: { _ in .init(descriptor: NSAppleEventDescriptor(int32: 40), errorNumber: nil) })
        var readBack: Int?
        queue.suspend()
        volume.read(music) { readBack = $0 }
        volume.set(AppVolumeSetting(volume: 0.9), for: music)  // user drags after the read started
        queue.resume()
        await settle(queue)
        XCTAssertNil(readBack, "a stale read must not overwrite the just-dragged value")
    }

    func testReadReportsAppVolume() async {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = makeVolume(recorder, queue: queue, result: { _ in .init(descriptor: NSAppleEventDescriptor(int32: 40), errorNumber: nil) })
        var readBack: Int?
        volume.read(music) { readBack = $0 }
        await settle(queue)
        XCTAssertEqual(readBack, 40)
        XCTAssertEqual(recorder.scripts, ["tell application id \"com.apple.Music\" to get sound volume"])
    }

    func testFailureAndSuccessAreReported() async {
        let queue = DispatchQueue(label: "test")
        var results: [Bool] = []
        let errorNumber = Recorder()  // running=true means "fail" for this test
        let volume = ScriptedVolume(
            queue: queue,
            isRunning: { _ in true },
            run: { _ in .init(descriptor: nil, errorNumber: errorNumber.running ? -1743 : nil) },  // -1743: Apple Events not permitted
            onResult: { _, ok in results.append(ok) }
        )
        volume.set(AppVolumeSetting(volume: 0.3), for: music)
        await settle(queue)
        errorNumber.running = false
        volume.set(AppVolumeSetting(volume: 0.4), for: music)
        await settle(queue)
        XCTAssertEqual(results, [false, true])
    }

    func testReadPlayingState() async {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = makeVolume(recorder, queue: queue, result: { _ in .init(descriptor: NSAppleEventDescriptor(string: "playing"), errorNumber: nil) })
        var playing: Bool?
        volume.readIsPlaying(music) { playing = $0 }
        await settle(queue)
        XCTAssertEqual(playing, true)
        XCTAssertEqual(recorder.scripts, ["tell application id \"com.apple.Music\" to (player state as text)"])
    }

    // MARK: Verification (Music can apply rapid volume commands out of order)

    /// A fake Music whose volume can drift once to a stale value right after a set.
    private final class FakeMusic: @unchecked Sendable {
        private let lock = NSLock()
        private var volume = 100
        private var driftOnce: Int?
        private(set) var sets: [Int] = []
        init(driftOnce: Int?) { self.driftOnce = driftOnce }

        func run(_ script: String) -> ScriptedVolume.ScriptResult {
            lock.withLock {
                if let range = script.range(of: "set sound volume to ") {
                    let value = Int(script[range.upperBound...])!
                    sets.append(value)
                    volume = driftOnce ?? value
                    driftOnce = nil
                    return .init(descriptor: nil, errorNumber: nil)
                }
                return .init(descriptor: NSAppleEventDescriptor(int32: Int32(volume)), errorNumber: nil)
            }
        }
        var current: Int { lock.withLock { volume } }
    }

    private func makeVerifyingVolume(_ music: FakeMusic, queue: DispatchQueue) -> ScriptedVolume {
        ScriptedVolume(
            queue: queue,
            minSendInterval: 0,
            verifyDelay: 0.02,
            isRunning: { _ in true },
            run: { music.run($0) },
            onResult: { _, _ in }
        )
    }

    func testResendsWhenAppDriftsAfterFinalSet() async throws {
        let fake = FakeMusic(driftOnce: 36)
        let queue = DispatchQueue(label: "test")
        let volume = makeVerifyingVolume(fake, queue: queue)
        volume.set(AppVolumeSetting(volume: 0), for: music)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sets, [0, 0], "the drifted value must be corrected by re-sending")
        XCTAssertEqual(fake.current, 0)
    }

    func testNoResendWhenAppMatches() async throws {
        let fake = FakeMusic(driftOnce: nil)
        let queue = DispatchQueue(label: "test")
        let volume = makeVerifyingVolume(fake, queue: queue)
        volume.set(AppVolumeSetting(volume: 0.4), for: music)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sets, [40])
    }

    func testSendsAreSpacedByMinInterval() async throws {
        let recorder = Recorder()
        let queue = DispatchQueue(label: "test")
        let volume = ScriptedVolume(
            queue: queue, minSendInterval: 0.1, verifyDelay: 3600,
            isRunning: { _ in true },
            run: { recorder.record($0); return .init(descriptor: nil, errorNumber: nil) },
            onResult: { _, _ in }
        )
        // A 300 ms drag of 30 values should send only a handful, ending on the last one.
        for step in stride(from: 30, through: 0, by: -1) {
            volume.set(AppVolumeSetting(volume: Float(step) / 100), for: music)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(recorder.scripts.count, 6)
        XCTAssertEqual(recorder.scripts.last, "tell application id \"com.apple.Music\" to set sound volume to 0")
    }
}
