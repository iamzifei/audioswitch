import AVFoundation
import XCTest

@testable import AudioSwitchCore

/// Tests for the level meter's measurement maths. The audio engine itself is
/// not started here — that would require microphone permission and a live
/// signal — but the dBFS conversion and the bar mapping are pure functions.
final class InputLevelMeterTests: XCTestCase {

    private func makeBuffer(samples: [Float], channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            for (index, sample) in samples.enumerated() {
                buffer.floatChannelData![channel][index] = sample
            }
        }
        return buffer
    }

    // MARK: - Peak measurement

    func testFullScaleSignalMeasuresZeroDBFS() {
        let buffer = makeBuffer(samples: [0, 1.0, -0.5, 0.2])
        XCTAssertEqual(InputLevelMeter.peakLevel(of: buffer), 0, accuracy: 0.01)
    }

    func testHalfAmplitudeIsAboutMinusSixDB() {
        let buffer = makeBuffer(samples: [0.5, -0.5])
        XCTAssertEqual(InputLevelMeter.peakLevel(of: buffer), -6.02, accuracy: 0.05)
    }

    func testSilenceFloorsInsteadOfReturningNegativeInfinity() {
        let buffer = makeBuffer(samples: [0, 0, 0, 0])
        XCTAssertEqual(InputLevelMeter.peakLevel(of: buffer), InputLevelMeter.floorDecibels)
    }

    func testVeryQuietSignalIsClampedToTheFloor() {
        // -100 dBFS is below the floor and must not drag the meter off scale.
        let buffer = makeBuffer(samples: [0.00001])
        XCTAssertEqual(InputLevelMeter.peakLevel(of: buffer), InputLevelMeter.floorDecibels)
    }

    func testPeakUsesTheLoudestChannel() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        // Quiet left, loud right: the meter must follow the right channel.
        buffer.floatChannelData![0][0] = 0.01
        buffer.floatChannelData![0][1] = 0.01
        buffer.floatChannelData![1][0] = 1.0
        buffer.floatChannelData![1][1] = 0.5
        XCTAssertEqual(InputLevelMeter.peakLevel(of: buffer), 0, accuracy: 0.01)
    }

    func testNegativePeaksCountAsLoudAsPositiveOnes() {
        // A waveform's troughs are as loud as its crests.
        let positive = makeBuffer(samples: [0.8])
        let negative = makeBuffer(samples: [-0.8])
        XCTAssertEqual(
            InputLevelMeter.peakLevel(of: positive),
            InputLevelMeter.peakLevel(of: negative),
            accuracy: 0.001
        )
    }

    // MARK: - Bar mapping

    func testNormalisationSpansTheWholeBar() {
        XCTAssertEqual(InputLevelMeter.normalise(decibels: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(
            InputLevelMeter.normalise(decibels: InputLevelMeter.floorDecibels), 0, accuracy: 0.001
        )
        XCTAssertEqual(InputLevelMeter.normalise(decibels: -30), 0.5, accuracy: 0.001)
    }

    func testNormalisationIsMonotonic() {
        let levels = [-60, -45, -30, -15, -6, 0].map {
            InputLevelMeter.normalise(decibels: Float($0))
        }
        XCTAssertEqual(levels, levels.sorted(), "louder input must never show a shorter bar")
    }

    func testNormalisationClampsOutOfRangeValues() {
        XCTAssertEqual(InputLevelMeter.normalise(decibels: -200), 0)
        // Digital clipping can exceed 0 dBFS; the bar must stay full, not overflow.
        XCTAssertEqual(InputLevelMeter.normalise(decibels: 12), 1.0, accuracy: 0.001)
    }

    // MARK: - Lifecycle

    @MainActor
    func testMeterStartsIdle() {
        let meter = InputLevelMeter()
        XCTAssertFalse(meter.isRunning)
        XCTAssertEqual(meter.level, 0)
        XCTAssertNil(meter.decibels)
    }

    @MainActor
    func testStoppingAnIdleMeterIsSafeAndResetsState() {
        let meter = InputLevelMeter()
        meter.stop()
        XCTAssertFalse(meter.isRunning)
        XCTAssertEqual(meter.level, 0)
    }
}
