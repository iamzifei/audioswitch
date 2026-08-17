import CoreAudio
import Foundation

/// The volume state of one device in one direction.
public struct VolumeState: Equatable, Sendable {
    /// 0.0 ... 1.0, matching the system volume slider.
    public var scalar: Float
    /// The same volume expressed in decibels, when the device reports it.
    /// Hardware ranges vary; typical built-in output is about -64 dB ... 0 dB.
    public var decibels: Float?
    public var isMuted: Bool
    /// False for devices that expose no software volume control at all
    /// (many HDMI outputs and some pro interfaces do their own gain).
    public var isSettable: Bool
    /// False when the device has no mute switch, so the UI can hide the button.
    public var isMuteSupported: Bool

    public static let unavailable = VolumeState(
        scalar: 0, decibels: nil, isMuted: false, isSettable: false, isMuteSupported: false
    )

    /// Value handed to SF Symbols' variable-value rendering, 0...1.
    ///
    /// `speaker.wave.3` is a variable symbol: one glyph whose wave arcs light up
    /// progressively. Driving it with a continuous value is how the system
    /// volume icon behaves — the outline stays the same width no matter how
    /// many arcs are lit, and the thresholds between arcs are Apple's rather
    /// than ours.
    public var symbolVariableValue: Double {
        guard !isMuted else { return 0 }
        return Double(min(max(scalar, 0), 1))
    }

    /// Nothing will come out of the device: either muted, or turned all the way
    /// down. The two are indistinguishable to the listener, so the icon treats
    /// them the same.
    public var isSilent: Bool {
        isMuted || scalar <= 0.001
    }

    /// Symbol to render in the menu bar. Silence and mute both use the slashed
    /// speaker; everything else uses the variable-value wave symbol.
    ///
    /// The `.fill` variants are deliberate: side-by-side capture of the system
    /// volume icon shows it draws a *solid* speaker cone with line-art waves.
    /// The outline variant looks visibly lighter than every neighbouring icon.
    public var menuBarSymbolName: String {
        isSilent ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }
}

/// Reads and writes hardware volume / mute for a device.
///
/// CoreAudio exposes volume in two shapes and devices support only one of them:
///
///   * a single "main" volume on element 0, or
///   * one volume per channel (element 1, 2, ...).
///
/// Every operation here tries the main element first and falls back to the
/// device's preferred stereo channels, which is what the system volume slider
/// does internally.
public enum VolumeController {

    // MARK: - Reading

    public static func state(
        deviceID: AudioObjectID,
        direction: AudioDirection
    ) -> VolumeState {
        let scope = direction.scope
        let elements = volumeElements(deviceID: deviceID, scope: scope)

        guard let firstElement = elements.first else {
            // No volume control: still report mute support, since some digital
            // outputs can be muted without being attenuated.
            let muteInfo = muteState(deviceID: deviceID, scope: scope)
            return VolumeState(
                scalar: 0,
                decibels: nil,
                isMuted: muteInfo.isMuted,
                isSettable: false,
                isMuteSupported: muteInfo.isSupported
            )
        }

        // With per-channel volume the channels can drift apart; the system
        // slider shows the loudest one, so we do the same.
        let scalar = elements.compactMap { element -> Float? in
            CoreAudioProperty.value(
                deviceID,
                CoreAudioProperty.address(
                    kAudioDevicePropertyVolumeScalar, scope: scope, element: element
                ),
                as: Float32.self
            )
        }.max() ?? 0

        let decibels = decibels(
            forScalar: scalar, deviceID: deviceID, scope: scope, element: firstElement
        )

        let muteInfo = muteState(deviceID: deviceID, scope: scope)

        return VolumeState(
            scalar: min(max(scalar, 0), 1),
            decibels: decibels,
            isMuted: muteInfo.isMuted,
            isSettable: isSettable(
                deviceID: deviceID,
                address: CoreAudioProperty.address(
                    kAudioDevicePropertyVolumeScalar, scope: scope, element: firstElement
                )
            ),
            isMuteSupported: muteInfo.isSupported
        )
    }

    // MARK: - Writing

    /// Sets the volume on every element the device exposes, so per-channel
    /// devices stay balanced instead of drifting to one side.
    @discardableResult
    public static func setVolume(
        _ scalar: Float,
        deviceID: AudioObjectID,
        direction: AudioDirection
    ) -> Bool {
        let scope = direction.scope
        let clamped = min(max(scalar, 0), 1)
        var didSet = false

        for element in volumeElements(deviceID: deviceID, scope: scope) {
            let address = CoreAudioProperty.address(
                kAudioDevicePropertyVolumeScalar, scope: scope, element: element
            )
            guard isSettable(deviceID: deviceID, address: address) else { continue }
            if CoreAudioProperty.setValue(deviceID, address, Float32(clamped)) == noErr {
                didSet = true
            }
        }

        // Raising the volume from zero should also lift mute, which is how the
        // hardware volume keys behave.
        if didSet, clamped > 0 {
            setMuted(false, deviceID: deviceID, direction: direction)
        }
        return didSet
    }

    @discardableResult
    public static func setMuted(
        _ muted: Bool,
        deviceID: AudioObjectID,
        direction: AudioDirection
    ) -> Bool {
        let scope = direction.scope
        var didSet = false

        // Mute lives on the main element for most devices, per channel for the rest.
        for element in [kAudioObjectPropertyElementMain] + volumeElements(deviceID: deviceID, scope: scope) {
            let address = CoreAudioProperty.address(
                kAudioDevicePropertyMute, scope: scope, element: element
            )
            guard isSettable(deviceID: deviceID, address: address) else { continue }
            if CoreAudioProperty.setValue(deviceID, address, UInt32(muted ? 1 : 0)) == noErr {
                didSet = true
                break
            }
        }
        return didSet
    }

    // MARK: - Decibels

    /// Converts the current scalar volume to decibels via CoreAudio's own
    /// conversion property.
    ///
    /// `kAudioDevicePropertyVolumeDecibels` is *not* used, even though it looks
    /// like the obvious choice: some devices return a meaningless value from it.
    /// Measured on this machine — an Audioengine 2+ at 12.5% volume reports
    /// 1.38e-30 dB from that property (a range of -40...0 dB), which renders as
    /// "0 dB" and contradicts both the slider and the audible level. The
    /// scalar→decibel conversion returns -35 dB for the same state, which is
    /// consistent with the slider.
    ///
    /// Deriving dB from the scalar we already display also guarantees the number
    /// and the slider position can never disagree.
    static func decibels(
        forScalar scalar: Float,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = CoreAudioProperty.address(
            kAudioDevicePropertyVolumeScalarToDecibels, scope: scope, element: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        // This property takes the scalar as input in the same buffer it writes
        // the result into.
        var value = Float32(scalar)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              value.isFinite
        else { return nil }

        // Reject anything outside the device's advertised range; a value that
        // falls outside it means the driver's conversion is unreliable too.
        if let range = decibelRange(deviceID: deviceID, scope: scope, element: element) {
            guard value >= Float(range.mMinimum) - 0.5,
                  value <= Float(range.mMaximum) + 0.5
            else { return nil }
        }
        return value
    }

    private static func decibelRange(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioValueRange? {
        let address = CoreAudioProperty.address(
            kAudioDevicePropertyVolumeRangeDecibels, scope: scope, element: element
        )
        guard hasProperty(deviceID: deviceID, address: address) else { return nil }
        return CoreAudioProperty.value(deviceID, address, as: AudioValueRange.self)
    }

    // MARK: - Element discovery

    /// The elements that carry a volume control for this device.
    ///
    /// Returns `[0]` when the device has a main volume, otherwise its preferred
    /// stereo channels, otherwise an empty array (no volume control at all).
    static func volumeElements(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        let mainAddress = CoreAudioProperty.address(
            kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain
        )
        if hasProperty(deviceID: deviceID, address: mainAddress) {
            return [kAudioObjectPropertyElementMain]
        }

        let stereo = CoreAudioProperty.array(
            deviceID,
            CoreAudioProperty.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope),
            of: UInt32.self
        )
        let channels = stereo.isEmpty ? [1, 2] : stereo
        return channels.filter { channel in
            hasProperty(
                deviceID: deviceID,
                address: CoreAudioProperty.address(
                    kAudioDevicePropertyVolumeScalar, scope: scope, element: channel
                )
            )
        }
    }

    private static func muteState(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> (isMuted: Bool, isSupported: Bool) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = CoreAudioProperty.address(
                kAudioDevicePropertyMute, scope: scope, element: AudioObjectPropertyElement(element)
            )
            guard hasProperty(deviceID: deviceID, address: address) else { continue }
            let value = CoreAudioProperty.value(deviceID, address, as: UInt32.self) ?? 0
            return (value != 0, true)
        }
        return (false, false)
    }

    static func hasProperty(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        return AudioObjectHasProperty(deviceID, &address)
    }

    private static func isSettable(
        deviceID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }
}
