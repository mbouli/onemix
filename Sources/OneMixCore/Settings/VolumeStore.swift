import Foundation

/// Persists per-app volume settings, keyed by bundle ID, and app preferences.
public final class VolumeStore {
    private enum Key {
        static let settings = "appVolumeSettings"
        static let showAllApps = "showAllApps"
    }

    private let defaults: UserDefaults
    private var cache: [String: AppVolumeSetting]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.settings),
           let decoded = try? JSONDecoder().decode([String: AppVolumeSetting].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    public func setting(for bundleID: String) -> AppVolumeSetting {
        cache[bundleID] ?? .default
    }

    public func save(_ setting: AppVolumeSetting, for bundleID: String) {
        cache[bundleID] = setting == .default ? nil : setting
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Key.settings)
        }
    }

    public var showAllApps: Bool {
        get { defaults.bool(forKey: Key.showAllApps) }
        set { defaults.set(newValue, forKey: Key.showAllApps) }
    }
}
