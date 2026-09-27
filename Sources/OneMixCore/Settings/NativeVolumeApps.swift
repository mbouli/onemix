import Foundation

/// Apps whose own volume OneMix drives (via AppleScript) instead of using a process tap.
///
/// Music is here because tapping it flattens Dolby Atmos to stereo, and on AirPods its
/// spatial audio path makes the Bluetooth stack slow down or speed up OneMix's replayed
/// stream whenever playback restarts (e.g. skipping to a lyric), which sounds like a
/// pitch drop and robotic fuzz.
public enum NativeVolumeApps {
    public static let bundleIDs: Set<String> = ["com.apple.Music"]

    /// Distributed notifications these apps post on every play/pause. Core Audio can take
    /// many seconds to list a process for Music after it starts playing, so these are the
    /// instant signal for whether the app is playing.
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

    /// Music rejects setting its `mute` property (AppleScript error 9038), so OneMix keeps
    /// mute itself and sends it as volume 0; unmuting sends the saved volume again.
    public static func scriptVolume(for setting: AppVolumeSetting) -> Int {
        setting.muted ? 0 : scriptVolume(setting.volume)
    }

    /// Maps the app's reported volume back onto `current`. While muted, the app sits at 0,
    /// which keeps the mute; any other value means the user changed it inside the app.
    public static func setting(scriptVolume: Int, current: AppVolumeSetting) -> AppVolumeSetting {
        if current.muted, scriptVolume == 0 { return current }
        return AppVolumeSetting(volume: Float(min(max(scriptVolume, 0), 100)) / 100, muted: false)
    }

    /// Tap targets for every audio group except native-volume apps, which are never tapped.
    public static func tapTargets(
        from groups: [String: AppAudioGroup],
        setting: (String) -> AppVolumeSetting
    ) -> [TapTarget] {
        groups.values
            .filter { !contains($0.app.bundleID) }
            .map { TapTarget(bundleID: $0.app.bundleID, processObjectIDs: $0.processObjectIDs, setting: setting($0.app.bundleID)) }
    }
}
