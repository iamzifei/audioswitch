import AppKit
import CoreAudio
import XCTest

@testable import AudioSwitchCore

/// Tests for the volume model: which glyph a level maps to, and the boundaries
/// between the buckets. The menu bar icon depends entirely on this mapping.
final class VolumeStateTests: XCTestCase {

    private func makeState(
        scalar: Float,
        isMuted: Bool = false,
        decibels: Float? = nil,
        isSettable: Bool = true,
        isMuteSupported: Bool = true
    ) -> VolumeState {
        VolumeState(
            scalar: scalar,
            decibels: decibels,
            isMuted: isMuted,
            isSettable: isSettable,
            isMuteSupported: isMuteSupported
        )
    }

    // MARK: - Menu bar symbol

    func testSilenceAndMuteBothUseTheSlashedSpeaker() {
        XCTAssertEqual(makeState(scalar: 0).menuBarSymbolName, "speaker.slash.fill")
        // Muted at full volume still reads as muted, like the system icon.
        XCTAssertEqual(makeState(scalar: 1.0, isMuted: true).menuBarSymbolName, "speaker.slash.fill")
    }

    func testNearZeroVolumeIsTreatedAsSilence() {
        // Hardware often reports a tiny non-zero scalar at the bottom of the
        // slider; showing a speaker with waves there would be wrong.
        XCTAssertEqual(makeState(scalar: 0.0005).menuBarSymbolName, "speaker.slash.fill")
    }

    func testAudibleVolumesAllUseTheSameWaveSymbol() {
        // One glyph for every audible level is what keeps the status item from
        // changing width — the arcs are driven by the variable value instead.
        for scalar in [Float(0.05), 0.3, 0.5, 0.8, 1.0] {
            XCTAssertEqual(
                makeState(scalar: scalar).menuBarSymbolName, "speaker.wave.3.fill",
                "scalar \(scalar) should not switch to a different-width glyph"
            )
        }
    }

    func testMenuBarSymbolsUseFilledVariants() {
        // Measured against the system volume icon: it draws a solid cone.
        XCTAssertTrue(makeState(scalar: 0.5).menuBarSymbolName.hasSuffix(".fill"))
        XCTAssertTrue(makeState(scalar: 0).menuBarSymbolName.hasSuffix(".fill"))
    }

    func testMenuBarSymbolsExistInSFSymbols() {
        // A typo in a symbol name yields a blank menu bar icon at runtime.
        for state in [makeState(scalar: 0.5), makeState(scalar: 0)] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: state.menuBarSymbolName, accessibilityDescription: nil),
                "SF Symbol \(state.menuBarSymbolName) does not exist"
            )
        }
    }

    func testSymbolsSupportVariableValueRendering() {
        // If the symbol were not variable, the arcs would never light up
        // progressively and the icon would look static.
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: "speaker.wave.3.fill",
                variableValue: 0.5,
                accessibilityDescription: nil
            )
        )
    }

    // MARK: - Variable value

    func testVariableValueTracksVolumeContinuously() {
        XCTAssertEqual(makeState(scalar: 0.0).symbolVariableValue, 0.0, accuracy: 0.001)
        XCTAssertEqual(makeState(scalar: 0.25).symbolVariableValue, 0.25, accuracy: 0.001)
        XCTAssertEqual(makeState(scalar: 0.5).symbolVariableValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(makeState(scalar: 1.0).symbolVariableValue, 1.0, accuracy: 0.001)
    }

    func testVariableValueIsMonotonic() {
        let values = [Float(0), 0.1, 0.3, 0.6, 0.9, 1.0].map {
            makeState(scalar: $0).symbolVariableValue
        }
        XCTAssertEqual(values, values.sorted(), "a louder level must never light fewer arcs")
    }

    func testMutingCollapsesTheVariableValueRegardlessOfVolume() {
        XCTAssertEqual(makeState(scalar: 0.9, isMuted: true).symbolVariableValue, 0)
    }

    func testVariableValueIsClampedToTheSymbolsRange() {
        // Out-of-range input would make SF Symbols reject the value.
        XCTAssertEqual(makeState(scalar: 1.8).symbolVariableValue, 1.0, accuracy: 0.001)
        XCTAssertEqual(makeState(scalar: -0.4).symbolVariableValue, 0.0, accuracy: 0.001)
    }

    // MARK: - Unavailable state

    func testUnavailableStateIsInertAndReadsAsMuted() {
        let state = VolumeState.unavailable
        XCTAssertFalse(state.isSettable)
        XCTAssertFalse(state.isMuteSupported)
        XCTAssertEqual(state.menuBarSymbolName, "speaker.slash.fill")
    }
}
