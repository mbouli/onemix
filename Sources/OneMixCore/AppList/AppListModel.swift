import CoreAudio
import Foundation

public struct RunningAppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t

    public init(bundleID: String, name: String, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// The audio process objects for an app and its helpers.
public struct AppAudioGroup: Equatable, Sendable {
    public let app: RunningAppInfo
    public var processObjectIDs: [AudioObjectID]
    public var isPlaying: Bool
}

public struct AppRowData: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pid: pid_t
    public let isPlaying: Bool
    public var volume: Float
    public var isMuted: Bool
}

public enum AppAttribution {
    /// Resolves the app that owns an audio process, by responsible PID first and then by
    /// longest bundle ID prefix (com.google.Chrome.helper → com.google.Chrome).
    public static func owner(of process: AudioProcess, responsiblePID: pid_t, apps: [RunningAppInfo]) -> RunningAppInfo? {
        if let app = apps.first(where: { $0.pid == responsiblePID }) { return app }
        guard let bundleID = process.bundleID else { return nil }
        return apps
            .filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}

public struct AppListModel {
    public static let gracePeriod: TimeInterval = 10

    /// Time each app was last seen playing or stopped.
    private var lastPlayed: [String: Date] = [:]
    private var playingLastTime: Set<String> = []

    public init() {}

    public static func group(
        processes: [AudioProcess],
        apps: [RunningAppInfo],
        responsiblePID: (pid_t) -> pid_t
    ) -> [String: AppAudioGroup] {
        var groups: [String: AppAudioGroup] = [:]
        for process in processes {
            guard let app = AppAttribution.owner(of: process, responsiblePID: responsiblePID(process.pid), apps: apps) else { continue }
            groups[app.bundleID, default: AppAudioGroup(app: app, processObjectIDs: [], isPlaying: false)]
                .processObjectIDs.append(process.objectID)
            if process.isRunningOutput { groups[app.bundleID]?.isPlaying = true }
        }
        for key in groups.keys { groups[key]?.processObjectIDs.sort() }
        return groups
    }

    public mutating func rows(
        apps: [RunningAppInfo],
        groups: [String: AppAudioGroup],
        showAllApps: Bool,
        now: Date,
        alsoPlaying: Set<String> = [],
        setting: (String) -> AppVolumeSetting
    ) -> [AppRowData] {
        // `alsoPlaying` covers apps that report playback before Core Audio lists them.
        let playingNow = Set(groups.values.filter(\.isPlaying).map(\.app.bundleID)).union(alsoPlaying)
        for bundleID in playingNow.union(playingLastTime) { lastPlayed[bundleID] = now }
        playingLastTime = playingNow
        lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < Self.gracePeriod }

        var seen = Set<String>()
        return apps
            .filter { seen.insert($0.bundleID).inserted }
            .filter { showAllApps || lastPlayed[$0.bundleID] != nil }
            .map { app in
                let saved = setting(app.bundleID)
                return AppRowData(
                    bundleID: app.bundleID,
                    name: app.name,
                    pid: app.pid,
                    isPlaying: playingNow.contains(app.bundleID),
                    volume: saved.volume,
                    isMuted: saved.muted
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// When the next idle app leaves the grace period, for scheduling a refresh.
    public func nextExpiry(now: Date) -> Date? {
        lastPlayed
            .filter { !playingLastTime.contains($0.key) }
            .map { $0.value + Self.gracePeriod }
            .filter { $0 > now }
            .min()
    }
}
