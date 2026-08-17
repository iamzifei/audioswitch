import AppKit
import CoreAudio
import XCTest

@testable import AudioSwitchCore

/// Tests for the menu bar glyph — the rules that let the icon show which kind
/// of device is playing, not just how loud it is.
final class MenuBarIconTests: XCTestCase {

    private func device(
        _ name: String,
        transport: AudioTransport = .bluetooth,
        inputChannels: Int = 2,
        outputDataSource: AudioDataSource? = nil
    ) -> AudioDevice {
        AudioDevice(
            id: 1,
            uid: name,
            name: name,
            transport: transport,
            inputChannels: inputChannels,
            outputChannels: 2,
            outputDataSource: outputDataSource
        )
    }

    private func volume(_ scalar: Float, isMuted: Bool = false) -> VolumeState {
        VolumeState(
            scalar: scalar, decibels: nil, isMuted: isMuted, isSettable: true, isMuteSupported: true
        )
    }

    // MARK: - Headphones take over the icon

    func testHeadphoneDevicesReplaceTheSpeakerGlyph() {
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: device("AirPods Pro"), volume: volume(0.5)), "airpods.pro"
        )
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: device("AirPods Max"), volume: volume(0.5)), "airpods.max"
        )
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: device("AirPods"), volume: volume(0.5)), "airpods"
        )
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: device("Beats Studio"), volume: volume(0.5)),
            "beats.headphones"
        )
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: device("Sony WH-1000XM5 Headphones"), volume: volume(0.5)),
            "headphones"
        )
    }

    func testWiredHeadphonesInTheBuiltInJackAreDetected() {
        // The built-in output keeps its device ID when a jack is plugged in;
        // the data source is what changes.
        let jack = device("External Headphones", transport: .builtIn, outputDataSource: .headphones)
        XCTAssertEqual(MenuBarIcon.symbolName(for: jack, volume: volume(0.5)), "headphones")
    }

    func testBluetoothHeadsetWithoutARecognisableNameStillGetsHeadphones() {
        // Falls through the name rules to the channel-layout heuristic.
        let headset = device("XR-2000", transport: .bluetooth, inputChannels: 1)
        XCTAssertEqual(MenuBarIcon.symbolName(for: headset, volume: volume(0.5)), "headphones")
    }

    // MARK: - Everything else keeps the speaker

    func testNonHeadphoneDevicesKeepTheVariableSpeakerGlyph() {
        let cases = [
            device("MacBook Pro Speakers", transport: .builtIn, outputDataSource: .internalSpeaker),
            device("HomePod", transport: .airPlay),
            device("Audioengine 2+", transport: .bluetooth, inputChannels: 0),
            device("Dell U2720Q", transport: .displayPort),
            device("BlackHole 2ch", transport: .virtual),
        ]
        for candidate in cases {
            XCTAssertEqual(
                MenuBarIcon.symbolName(for: candidate, volume: volume(0.5)),
                "speaker.wave.3.fill",
                "\(candidate.name) should not take over the menu bar icon"
            )
        }
    }

    func testNoDeviceFallsBackToTheVolumeGlyph() {
        XCTAssertEqual(MenuBarIcon.symbolName(for: nil, volume: volume(0.5)), "speaker.wave.3.fill")
        XCTAssertEqual(MenuBarIcon.symbolName(for: nil, volume: volume(0)), "speaker.slash.fill")
    }

    // MARK: - Silence wins over the device

    func testMutedHeadphonesStillShowTheSlashedSpeaker() {
        // There is no slashed headphones symbol, and "you will hear nothing" is
        // the more urgent of the two facts.
        let airpods = device("AirPods Pro")
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: airpods, volume: volume(0.8, isMuted: true)),
            "speaker.slash.fill"
        )
        XCTAssertEqual(
            MenuBarIcon.symbolName(for: airpods, volume: volume(0)), "speaker.slash.fill"
        )
    }

    // MARK: - Rendering contract

    func testOnlySpeakerSymbolsAreTreatedAsVariable() {
        XCTAssertTrue(MenuBarIcon.isVariable("speaker.wave.3.fill"))
        XCTAssertFalse(MenuBarIcon.isVariable("speaker.slash.fill"))
        for symbol in MenuBarIcon.headphoneSymbols {
            XCTAssertFalse(MenuBarIcon.isVariable(symbol), "\(symbol) has no variable form")
        }
    }

    func testEverySymbolTheMenuBarCanShowExists() {
        for symbol in MenuBarIcon.allSymbolNames {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "'\(symbol)' is not an SF Symbol"
            )
        }
    }

    func testAllSymbolNamesCoversTheGlyphsTheResolverCanReturn() {
        // The status item is padded to the width of this list, so a glyph
        // missing from it would make the item resize when that device connects.
        let samples: [AudioDevice] = [
            device("AirPods Pro"),
            device("AirPods Max"),
            device("AirPods"),
            device("Beats Studio"),
            device("Sony WH-1000XM5 Headphones"),
            device("MacBook Pro Speakers", transport: .builtIn, outputDataSource: .internalSpeaker),
            device("Dell U2720Q", transport: .displayPort),
        ]
        for candidate in samples {
            for state in [volume(0), volume(0.5), volume(1.0, isMuted: true)] {
                let symbol = MenuBarIcon.symbolName(for: candidate, volume: state)
                XCTAssertTrue(
                    MenuBarIcon.allSymbolNames.contains(symbol),
                    "\(candidate.name) resolved to '\(symbol)', which is not sized for"
                )
            }
        }
    }

    // MARK: - Silence helper

    func testIsSilentCoversBothMuteAndZeroVolume() {
        XCTAssertTrue(volume(0).isSilent)
        XCTAssertTrue(volume(0.0005).isSilent)
        XCTAssertTrue(volume(1.0, isMuted: true).isSilent)
        XCTAssertFalse(volume(0.02).isSilent)
    }
}
