import CoreAudio
import XCTest

@testable import OneMixCore

/// Records tap lifecycle events in call order, shared across a test's fake taps, so
/// tests can assert *when* a new tap is created relative to the old one being torn down.
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func reset() { events.removeAll() }
}

private struct TapFailure: Error {}

/// A fake `AudioTap` that records gain changes and invalidation instead of touching
/// Core Audio, so `AppVolumeController`'s rebuild logic can be tested without real taps.
private final class FakeTap: AudioTap {
    let processObjectIDs: [AudioObjectID]
    private(set) var outputUID: String
    var failRetarget = false
    private(set) var gainCalls: [Float] = []
    let startGain: Float
    private(set) var invalidated = false
    private let log: EventLog
    private let id: Int

    init(processObjectIDs: [AudioObjectID], outputUID: String, gain: Float, startGain: Float, log: EventLog, id: Int) {
        self.processObjectIDs = processObjectIDs
        self.startGain = startGain
        self.outputUID = outputUID
        gainCalls = [gain]
        self.log = log
        self.id = id
    }

    func setGain(_ value: Float) {
        gainCalls.append(value)
    }

    func retarget(outputUID: String) throws {
        if failRetarget { throw TapFailure() }
        log.record("retarget(\(id))")
        self.outputUID = outputUID
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        log.record("invalidate(\(id))")
    }
}

@MainActor
final class AppVolumeControllerTests: XCTestCase {
    /// Builds a controller whose fake taps are numbered in creation order and log to
    /// `log`. `shouldFail` decides, by that creation-order id, whether construction throws.
    private func makeController(
        log: EventLog,
        shouldFail: @escaping (Int) -> Bool = { _ in false },
        created: @escaping (FakeTap) -> Void = { _ in }
    ) -> AppVolumeController {
        var nextID = 0
        return AppVolumeController { processObjectIDs, outputUID, gain, startGain in
            let id = nextID
            nextID += 1
            if shouldFail(id) { throw TapFailure() }
            log.record("create(\(id))")
            let tap = FakeTap(processObjectIDs: processObjectIDs, outputUID: outputUID, gain: gain, startGain: startGain, log: log, id: id)
            created(tap)
            return tap
        }
    }

    private let bundleID = "com.example.app"

    // (a) Calling setOutputDevice with the same UID twice rebuilds the taps.
    func testSetOutputDeviceWithSameUIDTwiceRebuildsTaps() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        XCTAssertEqual(controller.activeTapCount, 1)

        log.reset()
        controller.setOutputDevice(uid: "device-1")

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertEqual(log.events, ["create(1)", "invalidate(0)"], "the new tap must be created before the old one is invalidated")
    }

    // (b) When process IDs change, the new tap is created before the old one is invalidated.
    func testProcessIDChangeCreatesNewTapBeforeInvalidatingOldOne() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])

        log.reset()
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [2], setting: AppVolumeSetting(volume: 0.3)))

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertEqual(log.events, ["create(1)", "invalidate(0)"])
    }

    // (c) When construction fails during a rebuild, the old tap is invalidated and the
    // bundle ID lands in failedBundleIDs.
    func testFailedRebuildInvalidatesOldTapAndRecordsFailure() {
        let log = EventLog()
        let controller = makeController(log: log, shouldFail: { id in id == 1 })
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        XCTAssertEqual(controller.activeTapCount, 1)

        log.reset()
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [2], setting: AppVolumeSetting(volume: 0.3)))

        XCTAssertEqual(controller.activeTapCount, 0, "the failed rebuild must not leave a stale tap behind")
        XCTAssertEqual(controller.failedBundleIDs, [bundleID])
        XCTAssertEqual(log.events, ["invalidate(0)"], "the old tap is invalidated even though the replacement failed")
    }

    // (d) rebuildAll() invalidates the existing taps and recreates them.
    func testRebuildAllInvalidatesAndRecreatesExistingTaps() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        XCTAssertEqual(controller.activeTapCount, 1)

        log.reset()
        controller.rebuildAll()

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertEqual(log.events, ["create(1)", "invalidate(0)"])
        XCTAssertTrue(controller.failedBundleIDs.isEmpty)
    }

    // (e) retryFailed() after a failure re-attempts construction.
    func testRetryFailedReattemptsConstruction() {
        let log = EventLog()
        var failNextConstruction = true
        let controller = makeController(log: log, shouldFail: { _ in
            if failNextConstruction {
                failNextConstruction = false
                return true
            }
            return false
        })
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        XCTAssertEqual(controller.activeTapCount, 0)
        XCTAssertEqual(controller.failedBundleIDs, [bundleID])

        controller.retryFailed()

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertTrue(controller.failedBundleIDs.isEmpty)
    }

    // Returning to 100% keeps the existing tap at full gain instead of tearing it down,
    // so there is no audio gap on the way back.
    func testReturningToFullVolumeKeepsTapAtFullGain() {
        let log = EventLog()
        var taps: [FakeTap] = []
        let controller = makeController(log: log, created: { taps.append($0) })
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])

        log.reset()
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: .default))

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertEqual(log.events, [], "no teardown or rebuild when returning to 100%")
        XCTAssertEqual(taps.first?.gainCalls.last, 1)
    }

    // A kept tap still follows process changes (rebuilt at full gain), so a routed app
    // at 100% never falls back to native audio mid-session.
    func testRoutedAppAtFullVolumeIsRebuiltWhenProcessesChange() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: .default))

        log.reset()
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [1, 2], setting: .default))

        XCTAssertEqual(controller.activeTapCount, 1)
        XCTAssertEqual(log.events, ["create(1)", "invalidate(0)"])
    }

    // Once the app goes away (dropped from sync), routing is forgotten: when it comes back
    // at 100% it plays natively with no tap.
    func testAppLeavingForgetsRouting() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        controller.sync([])
        XCTAssertEqual(controller.activeTapCount, 0)

        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [3], setting: .default)])

        XCTAssertEqual(controller.activeTapCount, 0)
    }

    // A never-adjusted app at 100% gets no tap.
    func testUntouchedAppAtFullVolumeGetsNoTap() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: .default)])
        XCTAssertEqual(controller.activeTapCount, 0)
        XCTAssertEqual(log.events, [])
    }

    // The first tap for an app ramps from native full volume down to the target, while a
    // replacement tap starts at the target gain (it takes over from an already-quieted tap).
    func testFirstTapRampsFromFullVolumeReplacementStartsAtTarget() {
        let log = EventLog()
        var taps: [FakeTap] = []
        let controller = makeController(log: log, created: { taps.append($0) })
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [2], setting: AppVolumeSetting(volume: 0.3)))

        XCTAssertEqual(taps.map(\.startGain), [1, 0.3])
    }

    // Switching to a different output moves the running tap in place instead of rebuilding
    // it: stopping and restarting a tap's IO makes macOS Bluetooth smart routing hijack the
    // output back to in-ear AirPods.
    func testOutputChangeMovesTapInPlace() {
        let log = EventLog()
        var taps: [FakeTap] = []
        let controller = makeController(log: log, created: { taps.append($0) })
        controller.setOutputDevice(uid: "airpods")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])

        log.reset()
        controller.setOutputDevice(uid: "speakers")

        XCTAssertEqual(log.events, ["retarget(0)"])
        XCTAssertEqual(taps.first?.outputUID, "speakers")
        XCTAssertEqual(controller.activeTapCount, 1)
    }

    func testFailedMoveFallsBackToRebuild() {
        let log = EventLog()
        let controller = makeController(log: log, created: { $0.failRetarget = true })
        controller.setOutputDevice(uid: "airpods")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])

        log.reset()
        controller.setOutputDevice(uid: "speakers")

        XCTAssertEqual(log.events, ["create(1)", "invalidate(0)"])
        XCTAssertEqual(controller.activeTapCount, 1)
    }
}
