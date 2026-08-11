import CoreAudio
import Foundation

/// Which side of the audio pipeline a device (or a user action) refers to.
public enum AudioDirection: String, CaseIterable, Sendable {
    case output
    case input

    /// Title shown above the device group in the menu.
    public var title: String {
        switch self {
        case .output: return "Output"
        case .input: return "Input"
        }
    }

    /// CoreAudio scope used when querying channel counts for this direction.
    var scope: AudioObjectPropertyScope {
        switch self {
        case .output: return kAudioObjectPropertyScopeOutput
        case .input: return kAudioObjectPropertyScopeInput
        }
    }

    /// Selector for reading / writing the system-wide default device.
    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        }
    }
}

/// How a device is physically (or virtually) attached to the Mac.
///
/// Used purely for picking an icon — the transport has no effect on switching.
public enum AudioTransport: Sendable {
    case builtIn
    case bluetooth
    case usb
    case displayPort   // HDMI / DisplayPort audio
    case thunderbolt
    case airPlay
    case virtual       // aggregate, multi-output, or software devices (Loopback, BlackHole, ...)
    case unknown

    /// Maps CoreAudio's `kAudioDevicePropertyTransportType` constant onto our enum.
    init(transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire:
            self = .thunderbolt
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            self = .virtual
        default:
            self = .unknown
        }
    }

    /// Fallback SF Symbol when nothing more specific can be determined.
    /// Direction matters because the same transport should look like a speaker
    /// on the output side and like a microphone on the input side.
    public func symbolName(for direction: AudioDirection) -> String {
        switch self {
        case .bluetooth:
            // Most Bluetooth audio outputs are headphones; CoreAudio does not
            // expose the Bluetooth Class-of-Device that would let us tell a
            // headset from a speaker, so name matching handles the exceptions.
            return direction == .input ? "mic" : "headphones"
        case .usb:
            return direction == .input ? "mic" : "hifispeaker"
        case .displayPort:
            return "display"
        case .thunderbolt:
            return "bolt"
        case .airPlay:
            return "airplayaudio"
        case .virtual:
            return "waveform.circle"
        case .builtIn, .unknown:
            return direction == .input ? "mic" : "speaker.wave.2"
        }
    }
}

/// CoreAudio's `kAudioDevicePropertyDataSource` values we care about.
///
/// Only built-in hardware reports these (measured on this machine: the built-in
/// speakers report `ispk` and the built-in mic `imic`); Bluetooth, HDMI and
/// virtual devices report nothing.
public enum AudioDataSource: Sendable {
    case internalSpeaker
    case headphones
    case internalMicrophone
    case lineOut
    case lineIn
    case other

    init(rawValue: UInt32) {
        // Four-character codes, e.g. 'ispk'.
        switch rawValue {
        case 0x6973_706B: self = .internalSpeaker   // ispk
        case 0x6864_706E: self = .headphones        // hdpn
        case 0x696D_6963: self = .internalMicrophone // imic
        case 0x6C69_6E6F: self = .lineOut           // lino
        case 0x6C69_6E69: self = .lineIn            // lini
        default: self = .other
        }
    }

    var symbolName: String? {
        switch self {
        case .internalSpeaker: return "laptopcomputer"
        case .headphones: return "headphones"
        case .internalMicrophone: return "mic"
        case .lineOut, .lineIn: return "cable.connector"
        case .other: return nil
        }
    }
}

/// Picks a per-device icon the way the system Bluetooth menu does: a distinct
/// glyph per kind of device rather than one glyph per connection type.
///
/// Resolution order, strongest signal first:
///   1. the device name (the only way to tell AirPods from a Bluetooth speaker),
///   2. the CoreAudio data source (built-in speakers vs the headphone jack),
///   3. the transport type as a fallback.
enum DeviceIconResolver {

    /// Name fragments checked in order; the first match wins, so more specific
    /// entries (airpods.max) must precede broader ones (airpods).
    private static let nameRules: [(needles: [String], symbol: String, directions: Set<AudioDirection>)] = [
        (["airpods max"], "airpods.max", [.input, .output]),
        (["airpods pro"], "airpods.pro", [.input, .output]),
        (["airpods"], "airpods", [.input, .output]),
        (["beats"], "beats.headphones", [.input, .output]),
        (["homepod"], "homepod", [.output]),
        (["apple tv", "appletv"], "appletv", [.output]),
        (["headphone", "headset", "耳机"], "headphones", [.input, .output]),
        (["earbud", "buds"], "airpods", [.input, .output]),
        // Microphone names only claim the input side: a mic that also exposes an
        // output is exposing a monitoring jack, which is headphones.
        (["microphone", "mic ", " mic", "麦克风"], "mic", [.input]),
        (["webcam", "camera", "cam "], "web.camera", [.input]),
        (["iphone"], "iphone", [.input, .output]),
        (["ipad"], "ipad", [.input, .output]),
        (["watch"], "applewatch", [.output]),
        (["soundbar", "hifi", "speaker", "音箱", "扬声器"], "hifispeaker", [.output]),
        (["display", "monitor", "tv"], "display", [.output]),
    ]

    static func symbolName(for device: AudioDevice, direction: AudioDirection) -> String {
        let name = device.name.lowercased()

        for rule in nameRules where rule.directions.contains(direction) {
            if rule.needles.contains(where: { name.contains($0) }) {
                // "MacBook Pro Speakers" matches "speaker", but the built-in
                // laptop speakers should look like a Mac, not a hi-fi.
                if rule.symbol == "hifispeaker", device.transport == .builtIn {
                    return "laptopcomputer"
                }
                return rule.symbol
            }
        }

        if let source = device.dataSource(for: direction)?.symbolName {
            return source
        }

        // Bluetooth has no Class-of-Device we can read, but the channel layout
        // is a good proxy: a headset carries a microphone, so an output-only
        // Bluetooth device is a speaker (an Audioengine 2+ rather than AirPods).
        if device.transport == .bluetooth, direction == .output {
            return device.inputChannels > 0 ? "headphones" : "hifispeaker"
        }

        return device.transport.symbolName(for: direction)
    }
}

/// A snapshot of one audio device as reported by CoreAudio.
///
/// `id` is the CoreAudio object ID, which is only valid for the current boot of
/// coreaudiod; `uid` is the stable identifier that survives replug/reboot.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    public let inputChannels: Int
    public let outputChannels: Int
    /// Mirrors `kAudioDevicePropertyDeviceCanBeDefaultDevice` per direction.
    public let canBeDefaultInput: Bool
    public let canBeDefaultOutput: Bool
    /// `kAudioDevicePropertyDataSource` per direction; only built-in hardware
    /// reports it, and it is what distinguishes the internal speakers from the
    /// headphone jack on the same device.
    public let outputDataSource: AudioDataSource?
    public let inputDataSource: AudioDataSource?

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        transport: AudioTransport,
        inputChannels: Int,
        outputChannels: Int,
        canBeDefaultInput: Bool = true,
        canBeDefaultOutput: Bool = true,
        outputDataSource: AudioDataSource? = nil,
        inputDataSource: AudioDataSource? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.canBeDefaultInput = canBeDefaultInput
        self.canBeDefaultOutput = canBeDefaultOutput
        self.outputDataSource = outputDataSource
        self.inputDataSource = inputDataSource
    }

    func dataSource(for direction: AudioDirection) -> AudioDataSource? {
        direction == .output ? outputDataSource : inputDataSource
    }

    /// A device belongs in a direction's list only if it carries channels in
    /// that direction **and** CoreAudio says it may become the default device.
    ///
    /// The second condition is what System Settings → Sound uses, and it is why
    /// things like the individual members of an aggregate device do not show up
    /// there. Filtering on channel count alone would list more devices than the
    /// system does.
    public func supports(_ direction: AudioDirection) -> Bool {
        switch direction {
        case .input: return inputChannels > 0 && canBeDefaultInput
        case .output: return outputChannels > 0 && canBeDefaultOutput
        }
    }

    /// Icon for this device in this direction — a distinct glyph per kind of
    /// device, in the style of the system Bluetooth menu.
    public func symbolName(for direction: AudioDirection) -> String {
        DeviceIconResolver.symbolName(for: self, direction: direction)
    }
}

extension Array where Element == AudioDevice {
    /// Devices usable in `direction`, sorted for stable display.
    ///
    /// Sorting is by name (case-insensitive) rather than by CoreAudio's
    /// arbitrary enumeration order, so entries do not jump around between
    /// refreshes. `uid` breaks ties for devices that share a name (two
    /// identical USB interfaces, for example).
    public func devices(for direction: AudioDirection) -> [AudioDevice] {
        filter { $0.supports(direction) }
            .sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.uid < $1.uid
            }
    }
}
