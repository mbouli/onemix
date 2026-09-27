import CoreAudio
import XCTest
@testable import OneMixCore

final class DeviceTransportTests: XCTestCase {
    func testBuiltInMatchesMockupLabelAndIcon() {
        let transport = DeviceTransport(code: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertEqual(transport, .builtIn)
        XCTAssertEqual(transport.label, "Built-in")
        XCTAssertEqual(transport.symbolName, "laptopcomputer")
    }

    func testBluetoothLEMapsToBluetooth() {
        XCTAssertEqual(DeviceTransport(code: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(DeviceTransport.bluetooth.symbolName, "headphones")
    }

    func testUnknownCodeIsOther() {
        XCTAssertEqual(DeviceTransport(code: 0), .other)
        XCTAssertEqual(DeviceTransport.other.label, "External")
    }

    func testDriftCompensationOffOnlyForBluetooth() {
        XCTAssertFalse(DeviceTransport.bluetooth.usesTapDriftCompensation)
        XCTAssertTrue(DeviceTransport.builtIn.usesTapDriftCompensation)
        XCTAssertTrue(DeviceTransport.usb.usesTapDriftCompensation)
    }
}
