import CoreAudio

public enum DeviceTransport: Equatable, Sendable {
    case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other

    public init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        default: self = .other
        }
    }

    public var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .virtual: "Virtual"
        case .aggregate: "Aggregate"
        case .other: "External"
        }
    }

    /// Whether to enable drift compensation. Disabled for Bluetooth: AirPods vary their clock
    /// rate by up to ±10% when changing latency, and the compensator stalls chasing it.
    public var usesTapDriftCompensation: Bool { self != .bluetooth }

    public var symbolName: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .hdmi: "tv"
        case .displayPort, .thunderbolt: "display"
        case .airPlay: "airplayaudio"
        case .virtual, .aggregate: "waveform"
        case .other: "hifispeaker"
        }
    }
}
