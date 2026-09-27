import CoreAudio
import Foundation

public enum OneMixIDs {
    /// UID prefix for our private aggregate devices, so they can be hidden from device lists.
    public static let aggregateUIDPrefix = "com.onemix.aggregate."
}

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String
    public var description: String { "\(operation) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

/// Thin typed wrappers over AudioObject property calls.
enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    /// Wraps `AudioObjectIsPropertySettable`, treating any error as "not settable".
    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(object, &address, &settable)
        return status == noErr && settable.boolValue
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get property \(address.mSelector)")
        return value
    }

    static func getString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "get string \(address.mSelector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func getObjectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "get size \(address.mSelector)")
        let stride = MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids), "get list \(address.mSelector)")
        return Array(ids.prefix(Int(size) / stride))
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        try check(
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value),
            "set property \(address.mSelector)"
        )
    }
}

/// Listens to one Core Audio property on the main queue for as long as this object lives.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
