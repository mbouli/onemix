import AudioToolbox
import CoreAudio
import Observation

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: DeviceTransport
}

/// Output devices and the default output's volume and mute, kept current through Core Audio
/// listeners so changes from volume keys and Control Center are reflected.
@MainActor @Observable
public final class OutputDeviceManager {
    public private(set) var devices: [OutputDevice] = []
    public private(set) var defaultOutput: OutputDevice?
    public private(set) var volume: Float = 0
    public private(set) var isMuted = false
    public private(set) var hasVolumeControl = false

    @ObservationIgnored public var onDefaultOutputChanged: (@MainActor (OutputDevice) -> Void)?
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []

    private static let volumeAddress = CA.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    private static let muteAddress = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    public init() {
        refreshDevices()
        refreshDefaultOutput()
        systemListeners = [
            PropertyListener(.system, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
                self?.refreshDevices()
            },
            PropertyListener(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.refreshDefaultOutput()
            },
        ]
    }

    public func setVolume(_ value: Float) {
        guard let id = defaultOutput?.id else { return }
        let clamped = min(max(value, 0), 1)
        try? CA.set(id, Self.volumeAddress, Float32(clamped))
        volume = clamped
        if isMuted, clamped > 0 { setMuted(false) }
    }

    public func setMuted(_ muted: Bool) {
        guard let id = defaultOutput?.id else { return }
        try? CA.set(id, Self.muteAddress, UInt32(muted ? 1 : 0))
        isMuted = muted
    }

    public func setDefaultOutput(_ device: OutputDevice) {
        try? CA.set(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
    }

    nonisolated static func outputDevice(uid: String) -> OutputDevice? {
        let ids = (try? CA.getObjectIDs(.system, CA.address(kAudioHardwarePropertyDevices))) ?? []
        return ids.lazy.compactMap(makeOutputDevice).first { $0.uid == uid }
    }

    private func refreshDevices() {
        let ids = (try? CA.getObjectIDs(.system, CA.address(kAudioHardwarePropertyDevices))) ?? []
        devices = ids.compactMap(Self.makeOutputDevice)
    }

    private func refreshDefaultOutput() {
        let id = (try? CA.get(.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID.unknown)) ?? .unknown
        let device = Self.makeOutputDevice(id)
        let changed = device?.id != defaultOutput?.id
        defaultOutput = device
        refreshVolume()
        guard let device else {
            deviceListeners = []
            return
        }
        guard changed else { return }
        deviceListeners = [
            PropertyListener(device.id, Self.volumeAddress) { [weak self] in self?.refreshVolume() },
            PropertyListener(device.id, Self.muteAddress) { [weak self] in self?.refreshVolume() },
        ]
        onDefaultOutputChanged?(device)
    }

    private func refreshVolume() {
        guard let id = defaultOutput?.id else {
            hasVolumeControl = false
            return
        }
        hasVolumeControl = CA.has(id, Self.volumeAddress) && CA.isSettable(id, Self.volumeAddress)
        volume = (try? CA.get(id, Self.volumeAddress, initial: Float32(0))) ?? 0
        isMuted = ((try? CA.get(id, Self.muteAddress, initial: UInt32(0))) ?? 0) != 0
    }

    nonisolated static func makeOutputDevice(_ id: AudioDeviceID) -> OutputDevice? {
        guard id != .unknown,
              let streams = try? CA.getObjectIDs(id, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)),
              !streams.isEmpty,
              let uid = try? CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(OneMixIDs.aggregateUIDPrefix)
        else { return nil }
        let name = (try? CA.getString(id, CA.address(kAudioObjectPropertyName))) ?? "Unknown Device"
        let transport = (try? CA.get(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, transport: DeviceTransport(code: transport))
    }
}
