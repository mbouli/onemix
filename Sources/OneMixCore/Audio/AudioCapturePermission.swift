import Foundation

/// System Audio Recording permission (kTCCServiceAudioCapture). There is no public API, so
/// this calls TCC's preflight and request functions directly, as Apple's AudioCap sample does.
public enum AudioCapturePermission {
    public enum Status: Equatable, Sendable { case granted, denied, unknown }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? = handle
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFunction.self) }

    private static let requestAccess: RequestFunction? = handle
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFunction.self) }

    public static func status() -> Status {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Prompts if needed. If TCC is unavailable, reports granted and lets tap creation prompt.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let requestAccess else {
            completion(true)
            return
        }
        requestAccess(service, nil) { granted in completion(granted) }
    }
}
