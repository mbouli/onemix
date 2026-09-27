import XCTest
@testable import OneMixCore

final class AppVolumeSettingTests: XCTestCase {
    func testDefaultIsFullVolumeUnmuted() {
        XCTAssertEqual(AppVolumeSetting.default, AppVolumeSetting(volume: 1, muted: false))
    }

    func testFullVolumeUnmutedNeedsNoTap() {
        XCTAssertFalse(AppVolumeSetting(volume: 1, muted: false).needsTap)
        XCTAssertFalse(AppVolumeSetting(volume: 0.996, muted: false).needsTap)
    }

    func testReducedVolumeNeedsTap() {
        XCTAssertTrue(AppVolumeSetting(volume: 0.5, muted: false).needsTap)
        XCTAssertTrue(AppVolumeSetting(volume: 0, muted: false).needsTap)
    }

    func testMutedNeedsTapEvenAtFullVolume() {
        XCTAssertTrue(AppVolumeSetting(volume: 1, muted: true).needsTap)
    }

    func testEffectiveGainIsZeroWhenMuted() {
        XCTAssertEqual(AppVolumeSetting(volume: 0.7, muted: true).effectiveGain, 0)
        XCTAssertEqual(AppVolumeSetting(volume: 0.7, muted: false).effectiveGain, 0.7)
    }
}
