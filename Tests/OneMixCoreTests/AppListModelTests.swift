import CoreAudio
import XCTest
@testable import OneMixCore

final class AppListModelTests: XCTestCase {
    private let music = RunningAppInfo(bundleID: "com.apple.Music", name: "Music", pid: 100)
    private let chrome = RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 200)
    private let zoom = RunningAppInfo(bundleID: "us.zoom.xos", name: "zoom.us", pid: 300)
    private var apps: [RunningAppInfo] { [music, chrome, zoom] }
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func proc(_ id: AudioObjectID, pid: pid_t, bundle: String?, playing: Bool) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: playing)
    }

    private func group(_ processes: [AudioProcess], responsible: [pid_t: pid_t] = [:]) -> [String: AppAudioGroup] {
        AppListModel.group(processes: processes, apps: apps, responsiblePID: { responsible[$0] ?? $0 })
    }

    // MARK: Attribution and grouping

    func testHelperAttributedByResponsiblePID() {
        let groups = group([proc(11, pid: 250, bundle: "com.apple.WebKit.GPU", playing: true)], responsible: [250: 200])
        XCTAssertEqual(groups["com.google.Chrome"]?.processObjectIDs, [11])
    }

    func testHelperAttributedByBundlePrefixWhenResponsiblePIDUnknown() {
        let groups = group([proc(12, pid: 260, bundle: "com.google.Chrome.helper", playing: true)])
        XCTAssertEqual(groups["com.google.Chrome"]?.processObjectIDs, [12])
    }

    func testUnownedProcessIsDropped() {
        let groups = group([proc(13, pid: 90, bundle: "com.apple.coreaudiod", playing: true)])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupIsPlayingIfAnyProcessPlaysAndIDsAreSorted() {
        let groups = group([
            proc(30, pid: 200, bundle: "com.google.Chrome", playing: false),
            proc(12, pid: 260, bundle: "com.google.Chrome.helper", playing: true),
        ])
        XCTAssertEqual(groups["com.google.Chrome"]?.processObjectIDs, [12, 30])
        XCTAssertEqual(groups["com.google.Chrome"]?.isPlaying, true)
    }

    // MARK: Rows

    func testPlayingModeShowsOnlyPlayingApps() {
        var model = AppListModel()
        let groups = group([
            proc(1, pid: 100, bundle: "com.apple.Music", playing: true),
            proc(2, pid: 300, bundle: "us.zoom.xos", playing: false),
        ])
        let rows = model.rows(apps: apps, groups: groups, showAllApps: false, now: t0, setting: { _ in .default })
        XCTAssertEqual(rows.map(\.bundleID), ["com.apple.Music"])
        XCTAssertEqual(rows.first?.isPlaying, true)
    }

    func testShowAllModeListsEveryAppSortedByName() {
        var model = AppListModel()
        let rows = model.rows(apps: [zoom, music, chrome], groups: [:], showAllApps: true, now: t0, setting: { _ in .default })
        XCTAssertEqual(rows.map(\.name), ["Google Chrome", "Music", "zoom.us"])
    }

    func testRowsCarrySavedSettings() {
        var model = AppListModel()
        let rows = model.rows(apps: [music], groups: [:], showAllApps: true, now: t0) { _ in
            AppVolumeSetting(volume: 0.35, muted: true)
        }
        XCTAssertEqual(rows.first?.volume, 0.35)
        XCTAssertEqual(rows.first?.isMuted, true)
    }

    func testDuplicateBundleIDsProduceOneRow() {
        var model = AppListModel()
        let second = RunningAppInfo(bundleID: "com.apple.Music", name: "Music", pid: 101)
        let rows = model.rows(apps: [music, second], groups: [:], showAllApps: true, now: t0, setting: { _ in .default })
        XCTAssertEqual(rows.count, 1)
    }

    func testQuietAppStaysListedForGracePeriodCountedFromWhenItStopped() {
        var model = AppListModel()
        let playing = group([proc(1, pid: 100, bundle: "com.apple.Music", playing: true)])
        let quiet = group([proc(1, pid: 100, bundle: "com.apple.Music", playing: false)])
        func visible(_ groups: [String: AppAudioGroup], at seconds: TimeInterval) -> Bool {
            !model.rows(apps: apps, groups: groups, showAllApps: false, now: t0 + seconds, setting: { _ in .default }).isEmpty
        }
        XCTAssertTrue(visible(playing, at: 0))
        XCTAssertTrue(visible(quiet, at: 5))    // stopped at t0+5
        XCTAssertTrue(visible(quiet, at: 14))   // 9 s after stopping
        XCTAssertFalse(visible(quiet, at: 16))  // 11 s after stopping
    }

    func testNextExpiryIsGracePeriodAfterAppGoesQuiet() {
        var model = AppListModel()
        let playing = group([proc(1, pid: 100, bundle: "com.apple.Music", playing: true)])
        let quiet = group([proc(1, pid: 100, bundle: "com.apple.Music", playing: false)])
        _ = model.rows(apps: apps, groups: playing, showAllApps: false, now: t0, setting: { _ in .default })
        XCTAssertNil(model.nextExpiry(now: t0))
        _ = model.rows(apps: apps, groups: quiet, showAllApps: false, now: t0 + 5, setting: { _ in .default })
        XCTAssertEqual(model.nextExpiry(now: t0 + 5), t0 + 15)
    }

    func testAppReportedPlayingIsListedWithoutAudioProcess() {
        var model = AppListModel()
        let rows = model.rows(apps: apps, groups: [:], showAllApps: false, now: t0, alsoPlaying: ["com.apple.Music"], setting: { _ in .default })
        XCTAssertEqual(rows.map(\.bundleID), ["com.apple.Music"])
        XCTAssertEqual(rows.first?.isPlaying, true)
    }

    func testAppReportedPausedGetsGracePeriod() {
        var model = AppListModel()
        _ = model.rows(apps: apps, groups: [:], showAllApps: false, now: t0, alsoPlaying: ["com.apple.Music"], setting: { _ in .default })
        let paused = model.rows(apps: apps, groups: [:], showAllApps: false, now: t0 + 5, alsoPlaying: [], setting: { _ in .default })
        XCTAssertEqual(paused.map(\.bundleID), ["com.apple.Music"])
        let later = model.rows(apps: apps, groups: [:], showAllApps: false, now: t0 + 16, alsoPlaying: [], setting: { _ in .default })
        XCTAssertTrue(later.isEmpty)
    }
}
