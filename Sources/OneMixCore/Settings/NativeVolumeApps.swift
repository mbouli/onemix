import Foundation

/// Apps whose volume is set through AppleScript rather than a process tap.
///
/// Tapping Music downmixes Dolby Atmos to stereo, and on AirPods the spatial audio path
/// makes the Bluetooth stack resample the replayed stream whenever playback restarts,
/// which is audible as pitch drift and distortion.
public enum NativeVolumeApps {
    public static let bundleIDs: Set<String> = ["com.apple.Music"]

    /// Distributed notifications posted on play/pause. Core Audio can take several seconds
    /// to list Music's process after playback starts, so these are the faster signal.
    public static let playerInfoNotifications: [String: String] = ["com.apple.Music": "com.apple.Music.playerInfo"]

    public static func isPlaying(playerInfo: [AnyHashable: Any]?) -> Bool {
        (playerInfo?["Player State"] as? String) == "Playing"
    }

    public static func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Music's `sound volume` is an integer 0...100.
    public static func scriptVolume(_ volume: Float) -> Int {
        Int((min(max(volume, 0), 1) * 100).rounded())
    }

    /// Music rejects writes to `mute` (AppleScript error 9038), so mute is tracked locally
    /// and sent as volume 0.
    public static func scriptVolume(for setting: AppVolumeSetting) -> Int {
        setting.muted ? 0 : scriptVolume(setting.volume)
    }

    /// Maps a volume read from the app back onto `current`. A 0 while muted keeps the mute;
    /// any other value is a change made in the app.
    public static func setting(scriptVolume: Int, current: AppVolumeSetting) -> AppVolumeSetting {
        if current.muted, scriptVolume == 0 { return current }
        return AppVolumeSetting(volume: Float(min(max(scriptVolume, 0), 100)) / 100, muted: false)
    }

    /// Tap targets for all audio groups except native-volume apps.
    public static func tapTargets(
        from groups: [String: AppAudioGroup],
        setting: (String) -> AppVolumeSetting
    ) -> [TapTarget] {
        groups.values
            .filter { !contains($0.app.bundleID) }
            .map { TapTarget(bundleID: $0.app.bundleID, processObjectIDs: $0.processObjectIDs, setting: setting($0.app.bundleID)) }
    }
}
