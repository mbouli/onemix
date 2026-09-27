import Foundation

/// Volume and mute state for one app. Volume is 0...1; boost is not supported.
public struct AppVolumeSetting: Codable, Equatable, Sendable {
    public var volume: Float
    public var muted: Bool

    public init(volume: Float = 1, muted: Bool = false) {
        self.volume = volume
        self.muted = muted
    }

    public static let `default` = AppVolumeSetting()

    /// Unmuted apps at full volume play natively, without a tap.
    public var needsTap: Bool { muted || volume < 0.995 }

    public var effectiveGain: Float { muted ? 0 : volume }
}
