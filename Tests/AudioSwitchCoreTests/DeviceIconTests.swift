import AppKit
import CoreAudio
import XCTest

@testable import AudioSwitchCore

/// Tests for per-device icon resolution — the rules that give each kind of
/// device its own glyph instead of one glyph per connection type.
final class DeviceIconTests: XCTestCase {

    private func device(
        _ name: String,
        transport: AudioTransport = .bluetooth,
        outputDataSource: AudioDataSource? = nil,
        inputDataSource: AudioDataSource? = nil
    ) -> AudioDevice {
        AudioDevice(
            id: 1,
            uid: name,
            name: name,
            transport: transport,
            inputChannels: 2,
            outputChannels: 2,
            outputDataSource: outputDataSource,
            inputDataSource: inputDataSource
        )
    }

    // MARK: - Name rules

    func testAirPodsVariantsGetTheirOwnGlyphs() {
        XCTAssertEqual(device("AirPods Max").symbolName(for: .output), "airpods.max")
        XCTAssertEqual(device("James's AirPods Pro").symbolName(for: .output), "airpods.pro")
        XCTAssertEqual(device("AirPods").symbolName(for: .output), "airpods")
    }

    func testMoreSpecificNameRulesWinOverBroaderOnes() {
        // "AirPods Pro" also contains "airpods"; order must resolve it to the Pro glyph.
        XCTAssertEqual(device("AirPods Pro 2").symbolName(for: .output), "airpods.pro")
        // "AirPods Max" contains neither "pro" nor plain-only matching problems,
        // but must not fall through to "airpods".
        XCTAssertNotEqual(device("AirPods Max").symbolName(for: .output), "airpods")
    }

    func testNameMatchingIsCaseInsensitive() {
        XCTAssertEqual(device("AIRPODS PRO").symbolName(for: .output), "airpods.pro")
        XCTAssertEqual(device("beats studio").symbolName(for: .output), "beats.headphones")
    }

    func testHeadphonesAndSpeakersAreDistinguished() {
        XCTAssertEqual(device("Sony WH-1000XM5 Headphones").symbolName(for: .output), "headphones")
        XCTAssertEqual(device("Bose Soundbar 700").symbolName(for: .output), "hifispeaker")
        XCTAssertEqual(device("HomePod").symbolName(for: .output), "homepod")
    }

    func testChineseDeviceNamesAreRecognised() {
        XCTAssertEqual(device("小米蓝牙耳机").symbolName(for: .output), "headphones")
        XCTAssertEqual(device("客厅音箱").symbolName(for: .output), "hifispeaker")
    }

    // MARK: - Direction sensitivity

    func testMicrophoneNamesOnlyClaimTheInputSide() {
        // A "DJI Mic" exposes two devices: the microphone and a monitoring
        // output. The output must not be drawn as a microphone.
        let mic = device("DJI Mic Mini-ED20C3")
        XCTAssertEqual(mic.symbolName(for: .input), "mic")
        XCTAssertEqual(mic.symbolName(for: .output), "headphones")
    }

    func testAirPodsUseTheSameGlyphInBothDirections() {
        // A headset is the same object whichever way audio flows.
        let airpods = device("AirPods Pro")
        XCTAssertEqual(airpods.symbolName(for: .input), airpods.symbolName(for: .output))
    }

    // MARK: - Data source rules

    func testBuiltInSpeakersLookLikeAMacNotAHiFi() {
        // "MacBook Pro Speakers" matches the "speaker" rule, but the laptop's
        // own speakers should read as the machine.
        let speakers = device(
            "MacBook Pro Speakers", transport: .builtIn, outputDataSource: .internalSpeaker
        )
        XCTAssertEqual(speakers.symbolName(for: .output), "laptopcomputer")
    }

    func testHeadphoneJackIsDetectedFromDataSource() {
        // The built-in output device renames itself when a jack is plugged in,
        // but the data source is the reliable signal.
        let jack = device("External Headphones", transport: .builtIn, outputDataSource: .headphones)
        XCTAssertEqual(jack.symbolName(for: .output), "headphones")
    }

    func testBuiltInMicrophoneUsesTheMicGlyph() {
        let mic = device(
            "MacBook Pro Microphone", transport: .builtIn, inputDataSource: .internalMicrophone
        )
        XCTAssertEqual(mic.symbolName(for: .input), "mic")
    }

    func testDataSourceFourCharacterCodesAreDecoded() {
        // 'ispk', 'hdpn', 'imic' as CoreAudio reports them.
        XCTAssertEqual(AudioDataSource(rawValue: 0x6973_706B), .internalSpeaker)
        XCTAssertEqual(AudioDataSource(rawValue: 0x6864_706E), .headphones)
        XCTAssertEqual(AudioDataSource(rawValue: 0x696D_6963), .internalMicrophone)
        XCTAssertEqual(AudioDataSource(rawValue: 0), .other)
    }

    func testUnknownDataSourceFallsThroughToTransport() {
        let unknown = device("Some Interface", transport: .usb, outputDataSource: .other)
        XCTAssertEqual(unknown.symbolName(for: .output), "hifispeaker")
    }

    // MARK: - Transport fallback

    func testTransportProvidesTheFallbackGlyph() {
        XCTAssertEqual(device("M28U", transport: .displayPort).symbolName(for: .output), "display")
        XCTAssertEqual(
            device("BlackHole 2ch", transport: .virtual).symbolName(for: .output), "waveform.circle"
        )
        XCTAssertEqual(
            device("Living Room", transport: .airPlay).symbolName(for: .output), "airplayaudio"
        )
        XCTAssertEqual(
            device("Scarlett 2i2", transport: .usb).symbolName(for: .input), "mic"
        )
    }

    func testBluetoothHeadsetIsToldApartFromBluetoothSpeakerByItsMicrophone() {
        // CoreAudio exposes no Bluetooth Class-of-Device, so the channel layout
        // stands in for it: a headset has a mic, a speaker does not.
        let headset = AudioDevice(
            id: 1, uid: "h", name: "XR-2000", transport: .bluetooth,
            inputChannels: 1, outputChannels: 2
        )
        let speaker = AudioDevice(
            id: 2, uid: "s", name: "Audioengine 2+", transport: .bluetooth,
            inputChannels: 0, outputChannels: 2
        )
        XCTAssertEqual(headset.symbolName(for: .output), "headphones")
        XCTAssertEqual(speaker.symbolName(for: .output), "hifispeaker")
    }

    // MARK: - Every glyph must exist

    func testAllResolvedSymbolsExistInSFSymbols() {
        let samples: [(String, AudioTransport, AudioDataSource?)] = [
            ("AirPods Max", .bluetooth, nil),
            ("AirPods Pro", .bluetooth, nil),
            ("AirPods", .bluetooth, nil),
            ("Beats Studio", .bluetooth, nil),
            ("HomePod", .airPlay, nil),
            ("Apple TV", .airPlay, nil),
            ("Studio Headphones", .usb, nil),
            ("Galaxy Buds", .bluetooth, nil),
            ("Blue Yeti Microphone", .usb, nil),
            ("Logitech Webcam", .usb, nil),
            ("iPhone 15 Pro", .unknown, nil),
            ("iPad Pro", .unknown, nil),
            ("Apple Watch", .bluetooth, nil),
            ("Bose Soundbar", .bluetooth, nil),
            ("Dell Monitor", .displayPort, nil),
            ("MacBook Pro Speakers", .builtIn, .internalSpeaker),
            ("External Headphones", .builtIn, .headphones),
            ("Line Out", .builtIn, .lineOut),
            ("BlackHole 2ch", .virtual, nil),
            ("Thunderbolt Dock", .thunderbolt, nil),
            ("Unknown Box", .unknown, nil),
        ]

        for (name, transport, source) in samples {
            for direction in AudioDirection.allCases {
                let candidate = AudioDevice(
                    id: 1, uid: name, name: name, transport: transport,
                    inputChannels: 2, outputChannels: 2,
                    outputDataSource: direction == .output ? source : nil,
                    inputDataSource: direction == .input ? source : nil
                )
                let symbol = candidate.symbolName(for: direction)
                XCTAssertNotNil(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    "\(name) [\(direction)] resolved to '\(symbol)', which is not an SF Symbol"
                )
            }
        }
    }

    func testRealDevicesOnThisMachineAllResolveToValidSymbols() {
        // Guards against a device on this Mac resolving to a missing glyph,
        // which would render as a blank row.
        let manager = MainActor.assumeIsolated { AudioDeviceManager() }
        let devices = MainActor.assumeIsolated { manager.devices }
        for device in devices {
            for direction in AudioDirection.allCases where device.supports(direction) {
                let symbol = device.symbolName(for: direction)
                XCTAssertNotNil(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                    "\(device.name) resolved to '\(symbol)'"
                )
            }
        }
    }
}
