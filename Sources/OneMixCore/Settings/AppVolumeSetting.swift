import Foundation

/// A user's volume choice for one app. Volume is 0...1 (no boost).
public struct AppVolumeSetting: Codable, Equatable, Sendable {
    public var volume: Float
    public var muted: Bool

    public init(volume: Float = 1, muted: Bool = false) {
        self.volume = volume
        self.muted = muted
    }

    public static let `default` = AppVolumeSetting()

    /// Apps at full volume and unmuted play natively with no tap.
    public var needsTap: Bool { muted || volume < 0.995 }

    /// The gain the tap should apply.
    public var effectiveGain: Float { muted ? 0 : volume }
}
