import AppKit
import Observation
import OneMixCore
import ServiceManagement
import os

@MainActor @Observable
final class MixerViewModel {
    let devices = OutputDeviceManager()
    let controller = AppVolumeController()

    private(set) var rows: [AppRowData] = []
    private(set) var permission: AudioCapturePermission.Status
    private(set) var showAllApps: Bool
    private(set) var launchAtLogin: Bool
    /// Native-volume apps whose last AppleScript command failed (e.g. Automation denied).
    private(set) var nativeFailedBundleIDs: Set<String> = []

    private let monitor = AudioProcessMonitor()
    private let store: VolumeStore
    @ObservationIgnored private var listModel = AppListModel()
    @ObservationIgnored private var groups: [String: AppAudioGroup] = [:]
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var scriptedVolume: ScriptedVolume!
    /// Last setting pushed to each running native-volume app; cleared when the app quits
    /// so a relaunch gets the saved volume again.
    @ObservationIgnored private var pushedNative: [String: AppVolumeSetting] = [:]
    /// Native apps currently reporting playback via their playerInfo notification.
    @ObservationIgnored private var nativePlaying: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: "com.onemix.OneMix", category: "app")

    init() {
        let store = VolumeStore()
        self.store = store
        showAllApps = store.showAllApps
        launchAtLogin = SMAppService.mainApp.status == .enabled
        permission = AudioCapturePermission.status()
        scriptedVolume = ScriptedVolume(
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
            onResult: { [weak self] bundleID, succeeded in
                if succeeded {
                    self?.nativeFailedBundleIDs.remove(bundleID)
                } else {
                    self?.nativeFailedBundleIDs.insert(bundleID)
                }
            }
        )

        devices.onDefaultOutputChanged = { [weak self] device in
            self?.log.info("Default output changed to \(device.name, privacy: .public) (\(device.uid, privacy: .public))")
            self?.controller.setOutputDevice(uid: device.uid)
        }
        if let output = devices.defaultOutput { controller.setOutputDevice(uid: output.uid) }

        for (bundleID, name) in NativeVolumeApps.playerInfoNotifications {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] note in
                let playing = NativeVolumeApps.isPlaying(playerInfo: note.userInfo)
                MainActor.assumeIsolated { self?.setNativePlaying(bundleID, playing) }
            })
            scriptedVolume.readIsPlaying(bundleID) { [weak self] playing in self?.setNativePlaying(bundleID, playing) }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.removeAll() }
        })

        observeProcesses()
        if permission == .unknown { requestPermission() }
        refresh()
    }

    // MARK: Actions

    func setVolume(_ volume: Float, for bundleID: String) {
        var setting = store.setting(for: bundleID)
        setting.volume = min(max(volume, 0), 1)
        setting.muted = false  // dragging a slider unmutes, like the native volume
        update(setting, for: bundleID)
    }

    func toggleMute(for bundleID: String) {
        var setting = store.setting(for: bundleID)
        setting.muted.toggle()
        update(setting, for: bundleID)
    }

    func setShowAllApps(_ value: Bool) {
        showAllApps = value
        store.showAllApps = value
        refresh()
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called whenever the panel opens; picks up permission granted in System Settings.
    func panelDidOpen() {
        let latest = AudioCapturePermission.status()
        // `.unknown` from the preflight (TCC unavailable) must never downgrade a
        // current `.granted` or `.denied` that we already resolved elsewhere.
        let previous = permission
        if latest == .granted || latest == .denied {
            permission = latest
        }
        refresh()
        syncNativeVolumesFromApps()
        if permission == .granted, previous != .granted {
            controller.rebuildAll()
        } else if permission == .granted {
            controller.retryFailed()
        }
    }

    // MARK: Internals

    private func setNativePlaying(_ bundleID: String, _ playing: Bool) {
        log.info("\(bundleID, privacy: .public) reports playing=\(playing)")
        let changed = playing ? nativePlaying.insert(bundleID).inserted : nativePlaying.remove(bundleID) != nil
        if changed { refresh() }
    }

    private func update(_ setting: AppVolumeSetting, for bundleID: String) {
        store.save(setting, for: bundleID)
        if let index = rows.firstIndex(where: { $0.bundleID == bundleID }) {
            rows[index].volume = setting.volume
            rows[index].isMuted = setting.muted
        }
        if NativeVolumeApps.contains(bundleID) {
            pushNative(setting, for: bundleID)
        } else if permission == .granted, let group = groups[bundleID] {
            controller.apply(TapTarget(bundleID: bundleID, processObjectIDs: group.processObjectIDs, setting: setting))
        }
    }

    private func pushNative(_ setting: AppVolumeSetting, for bundleID: String) {
        guard pushedNative[bundleID] != setting || nativeFailedBundleIDs.contains(bundleID) else {
            log.info("Not re-sending \(bundleID, privacy: .public) volume \(setting.volume): unchanged")
            return
        }
        pushedNative[bundleID] = setting
        scriptedVolume.set(setting, for: bundleID)
    }

    /// Applies saved volumes to native-volume apps that are running (e.g. just launched).
    private func pushNativeVolumes(running apps: [RunningAppInfo]) {
        let running = Set(apps.map(\.bundleID))
        for bundleID in pushedNative.keys where !running.contains(bundleID) {
            pushedNative[bundleID] = nil
        }
        for bundleID in NativeVolumeApps.bundleIDs where running.contains(bundleID) {
            pushNative(store.setting(for: bundleID), for: bundleID)
        }
    }

    /// Picks up volume changes made inside the app itself (e.g. Music's own slider).
    private func syncNativeVolumesFromApps() {
        for bundleID in NativeVolumeApps.bundleIDs where pushedNative[bundleID] != nil {
            scriptedVolume.read(bundleID) { [weak self] scriptVolume in
                guard let self, let pushed = self.pushedNative[bundleID] else { return }
                let setting = NativeVolumeApps.setting(scriptVolume: scriptVolume, current: pushed)
                guard setting != pushed else { return }
                self.log.info("Read back \(bundleID, privacy: .public) volume \(scriptVolume) from the app")
                self.pushedNative[bundleID] = setting
                self.store.save(setting, for: bundleID)
                if let index = self.rows.firstIndex(where: { $0.bundleID == bundleID }) {
                    self.rows[index].volume = setting.volume
                    self.rows[index].isMuted = setting.muted
                }
            }
        }
    }

    private func refresh() {
        let apps = Self.runningApps()
        // A quit app can't be playing; its last playerInfo may have said "Playing".
        nativePlaying.formIntersection(apps.map(\.bundleID))
        groups = AppListModel.group(processes: monitor.processes, apps: apps, responsiblePID: ResponsiblePID.of)
        if permission == .granted {
            controller.sync(NativeVolumeApps.tapTargets(from: groups, setting: store.setting(for:)))
        } else {
            controller.sync([])
        }
        pushNativeVolumes(running: apps)
        let newRows = listModel.rows(apps: apps, groups: groups, showAllApps: showAllApps, now: .now, alsoPlaying: nativePlaying, setting: store.setting(for:))
        if newRows.map(\.bundleID) != rows.map(\.bundleID) {
            log.info("Listed apps: \(newRows.map(\.bundleID), privacy: .public); playing groups: \(self.groups.values.filter(\.isPlaying).map(\.app.bundleID), privacy: .public)")
        }
        rows = newRows
        scheduleGraceRefresh()
    }

    private func observeProcesses() {
        withObservationTracking {
            _ = monitor.processes
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeProcesses()
            }
        }
    }

    private func scheduleGraceRefresh() {
        graceTask?.cancel()
        guard let expiry = listModel.nextExpiry(now: .now) else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(expiry.timeIntervalSinceNow, 0) + 0.1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func requestPermission() {
        AudioCapturePermission.request { [weak self] granted in
            Task { @MainActor in
                self?.permission = granted ? .granted : .denied
                self?.refresh()
                if granted {
                    self?.controller.rebuildAll()
                }
            }
        }
    }

    private static func runningApps() -> [RunningAppInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier
            else { return nil }
            return RunningAppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
        }
    }
}
