import XCTest
@testable import OneMixCore

final class NativeVolumeAppsTests: XCTestCase {
    func testMusicUsesNativeVolume() {
        XCTAssertTrue(NativeVolumeApps.contains("com.apple.Music"))
        XCTAssertFalse(NativeVolumeApps.contains("com.google.Chrome"))
    }

    func testScriptVolumeMapsToZeroToHundred() {
        XCTAssertEqual(NativeVolumeApps.scriptVolume(0.6), 60)
        XCTAssertEqual(NativeVolumeApps.scriptVolume(0.004), 0)
        XCTAssertEqual(NativeVolumeApps.scriptVolume(1.5), 100)
        XCTAssertEqual(NativeVolumeApps.scriptVolume(-1), 0)
    }

    // Music rejects setting its `mute` property (error 9038), so mute is sent as volume 0.
    func testMutedSettingIsSentAsZeroVolume() {
        XCTAssertEqual(NativeVolumeApps.scriptVolume(for: AppVolumeSetting(volume: 0.6, muted: true)), 0)
        XCTAssertEqual(NativeVolumeApps.scriptVolume(for: AppVolumeSetting(volume: 0.6, muted: false)), 60)
    }

    func testReadBackKeepsMuteWhileAppIsSilent() {
        let muted = AppVolumeSetting(volume: 0.6, muted: true)
        XCTAssertEqual(NativeVolumeApps.setting(scriptVolume: 0, current: muted), muted)
    }

    func testReadBackUnmutesWhenVolumeRaisedInApp() {
        let muted = AppVolumeSetting(volume: 0.6, muted: true)
        XCTAssertEqual(NativeVolumeApps.setting(scriptVolume: 35, current: muted), AppVolumeSetting(volume: 0.35, muted: false))
    }

    func testReadBackTakesAppVolumeWhenUnmuted() {
        XCTAssertEqual(NativeVolumeApps.setting(scriptVolume: 140, current: .default), AppVolumeSetting(volume: 1, muted: false))
        XCTAssertEqual(NativeVolumeApps.setting(scriptVolume: 0, current: .default), AppVolumeSetting(volume: 0, muted: false))
    }

    func testTapTargetsExcludeNativeApps() {
        let music = RunningAppInfo(bundleID: "com.apple.Music", name: "Music", pid: 1)
        let chrome = RunningAppInfo(bundleID: "com.google.Chrome", name: "Chrome", pid: 2)
        let groups = [
            "com.apple.Music": AppAudioGroup(app: music, processObjectIDs: [10], isPlaying: true),
            "com.google.Chrome": AppAudioGroup(app: chrome, processObjectIDs: [20], isPlaying: true),
        ]
        let targets = NativeVolumeApps.tapTargets(from: groups) { _ in AppVolumeSetting(volume: 0.5) }
        XCTAssertEqual(targets.map(\.bundleID), ["com.google.Chrome"])
    }

    func testMusicPlayerInfoNotification() {
        XCTAssertEqual(NativeVolumeApps.playerInfoNotifications["com.apple.Music"], "com.apple.Music.playerInfo")
        XCTAssertTrue(NativeVolumeApps.isPlaying(playerInfo: ["Player State": "Playing", "Name": "Boys"]))
        XCTAssertFalse(NativeVolumeApps.isPlaying(playerInfo: ["Player State": "Paused"]))
        XCTAssertFalse(NativeVolumeApps.isPlaying(playerInfo: nil))
    }
}
