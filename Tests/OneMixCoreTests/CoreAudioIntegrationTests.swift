import XCTest
@testable import OneMixCore

@MainActor
final class CoreAudioIntegrationTests: XCTestCase {
    func testOutputDeviceManagerFindsDefaultOutput() throws {
        let manager = OutputDeviceManager()
        let output = try XCTUnwrap(manager.defaultOutput, "This Mac should have a default output device")
        XCTAssertTrue(manager.devices.contains(output))
        XCTAssertFalse(output.uid.hasPrefix(OneMixIDs.aggregateUIDPrefix))
        XCTAssertTrue((0...1).contains(manager.volume))
    }

    func testProcessMonitorExcludesOwnProcess() {
        let monitor = AudioProcessMonitor()
        XCTAssertFalse(monitor.processes.contains { $0.pid == getpid() })
        XCTAssertTrue(monitor.processes.allSatisfy { $0.pid > 0 })
    }

    func testResponsiblePIDOfSelfIsAPositivePID() {
        XCTAssertGreaterThan(ResponsiblePID.of(getpid()), 0)
    }

    func testFullVolumeTargetCreatesNoTap() {
        let controller = AppVolumeController()
        controller.setOutputDevice(uid: "unused")
        controller.sync([TapTarget(bundleID: "com.apple.Music", processObjectIDs: [42], setting: .default)])
        XCTAssertEqual(controller.activeTapCount, 0)
        XCTAssertTrue(controller.failedBundleIDs.isEmpty)
    }

    func testTargetWithoutProcessesCreatesNoTap() {
        let controller = AppVolumeController()
        controller.setOutputDevice(uid: "unused")
        controller.sync([TapTarget(bundleID: "com.apple.Music", processObjectIDs: [], setting: AppVolumeSetting(volume: 0.3))])
        XCTAssertEqual(controller.activeTapCount, 0)
    }

    func testRetryFailedWithNoTapTargetsStaysEmpty() {
        let controller = AppVolumeController()
        controller.setOutputDevice(uid: "unused")
        controller.sync([TapTarget(bundleID: "com.apple.Music", processObjectIDs: [42], setting: .default)])
        controller.retryFailed()
        XCTAssertEqual(controller.activeTapCount, 0)
        XCTAssertTrue(controller.failedBundleIDs.isEmpty)
    }
}
