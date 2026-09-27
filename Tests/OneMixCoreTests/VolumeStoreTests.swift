import XCTest
@testable import OneMixCore

final class VolumeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "OneMixTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnknownAppGetsDefaultSetting() {
        XCTAssertEqual(VolumeStore(defaults: defaults).setting(for: "com.example.app"), .default)
    }

    func testSavedSettingSurvivesNewStoreInstance() {
        VolumeStore(defaults: defaults).save(AppVolumeSetting(volume: 0.4, muted: true), for: "com.spotify.client")
        XCTAssertEqual(
            VolumeStore(defaults: defaults).setting(for: "com.spotify.client"),
            AppVolumeSetting(volume: 0.4, muted: true)
        )
    }

    func testSavingDefaultForgetsApp() {
        let store = VolumeStore(defaults: defaults)
        store.save(AppVolumeSetting(volume: 0.5), for: "com.apple.Music")
        store.save(.default, for: "com.apple.Music")
        XCTAssertEqual(VolumeStore(defaults: defaults).setting(for: "com.apple.Music"), .default)
    }

    func testShowAllAppsDefaultsOffAndPersists() {
        let store = VolumeStore(defaults: defaults)
        XCTAssertFalse(store.showAllApps)
        store.showAllApps = true
        XCTAssertTrue(VolumeStore(defaults: defaults).showAllApps)
    }
}
