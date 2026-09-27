import CoreAudio
import XCTest

@testable import OneMixCore

/// Shared log of tap lifecycle events, for asserting creation and teardown order.
private final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func reset() { events.removeAll() }
}

private struct TapFailure: Error {}

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
    /// Fake taps are numbered in creation order; `shouldFail` receives that number.
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

    func testUntouchedAppAtFullVolumeGetsNoTap() {
        let log = EventLog()
        let controller = makeController(log: log)
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: .default)])
        XCTAssertEqual(controller.activeTapCount, 0)
        XCTAssertEqual(log.events, [])
    }

    func testFirstTapRampsFromFullVolumeReplacementStartsAtTarget() {
        let log = EventLog()
        var taps: [FakeTap] = []
        let controller = makeController(log: log, created: { taps.append($0) })
        controller.setOutputDevice(uid: "device-1")
        controller.sync([TapTarget(bundleID: bundleID, processObjectIDs: [1], setting: AppVolumeSetting(volume: 0.3))])
        controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: [2], setting: AppVolumeSetting(volume: 0.3)))

        XCTAssertEqual(taps.map(\.startGain), [1, 0.3])
    }

    // Restarting IO would trigger Bluetooth automatic switching; see `ProcessTap.setOutputDevice`.
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
