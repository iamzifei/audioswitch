import CoreAudio
import Foundation

/// Thin, type-safe wrappers around the CoreAudio `AudioObjectGetPropertyData` /
/// `AudioObjectSetPropertyData` C API.
///
/// Every CoreAudio property read follows the same three-step dance:
///   1. build an `AudioObjectPropertyAddress` (selector + scope + element),
///   2. ask for the size of the value,
///   3. allocate a buffer of that size and read the value into it.
///
/// These helpers hide that boilerplate so the rest of the code reads like
/// ordinary Swift.
enum CoreAudioProperty {

    /// The well-known object ID representing the audio system itself.
    /// Global properties (list of devices, current default device, ...) are
    /// read from this object rather than from an individual device.
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Builds a property address. Almost every property we care about lives in
    /// the global scope on the main element, so those are the defaults.
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a single fixed-size value (`UInt32`, `AudioObjectID`, ...).
    /// Returns `nil` when the object does not implement the property.
    static func value<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        as type: T.Type = T.self
    ) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        // Allocate raw storage instead of using an uninitialised `T` so that we
        // never read an unset value if CoreAudio fails half-way through.
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
        guard status == noErr else { return nil }
        return buffer.pointee
    }

    /// Reads a variable-length array property, e.g. the list of all device IDs.
    static func array<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type = T.self
    ) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        // `T` here is always a trivial C type (AudioObjectID), so raw storage
        // that CoreAudio fills in is safe to read back without pre-initialising.
        let capacity = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer) == noErr else {
            return []
        }
        // CoreAudio may write fewer bytes than the size query advertised.
        let written = min(capacity, Int(size) / MemoryLayout<T>.stride)
        return Array(UnsafeBufferPointer(start: buffer, count: written))
    }

    /// Reads a `CFString` property (device name, device UID, ...) as a Swift `String`.
    ///
    /// CoreAudio hands back a +1 retained `CFStringRef`, so we take ownership
    /// with `takeRetainedValue()` to avoid leaking it.
    static func string(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> String? {
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = result?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Writes a single fixed-size value. Returns the raw `OSStatus` so callers
    /// can surface a meaningful error instead of a silent no-op.
    @discardableResult
    static func setValue<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: T
    ) -> OSStatus {
        var address = address
        return withUnsafeBytes(of: value) { raw in
            AudioObjectSetPropertyData(
                objectID, &address, 0, nil, UInt32(raw.count), raw.baseAddress!
            )
        }
    }

    /// Total number of channels a device exposes in the given scope.
    ///
    /// This is how a device's direction is determined: a device with input
    /// channels can be used as a microphone, one with output channels as a
    /// speaker. Aggregate devices (e.g. an iPhone via Continuity) can have both.
    static func channelCount(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }

        // AudioBufferList is a variable-length C struct, so it has to be read
        // into a manually sized raw allocation rather than a Swift value.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
