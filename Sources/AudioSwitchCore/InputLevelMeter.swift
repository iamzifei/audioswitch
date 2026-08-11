import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Live input level meter for the current default input device.
///
/// Taps the microphone through `AVAudioEngine` and publishes a smoothed level.
/// The engine is only running while something is observing (i.e. while the
/// panel is open), so the app does not hold the microphone — and does not show
/// the system's orange recording indicator — when idle.
@MainActor
public final class InputLevelMeter: ObservableObject {

    /// Normalised level for a meter bar, 0...1.
    @Published public private(set) var level: Float = 0

    /// Peak level in dBFS, or `nil` before the first buffer arrives.
    /// Silence floors at `Self.floorDecibels`.
    @Published public private(set) var decibels: Float?

    /// True once the user has granted microphone access.
    @Published public private(set) var isAuthorized = false

    /// Set when the meter cannot run, so the UI can explain why.
    @Published public private(set) var unavailableReason: String?

    public private(set) var isRunning = false

    /// Levels below this are treated as silence. -60 dBFS is roughly the noise
    /// floor of a quiet room on a typical microphone.
    ///
    /// `nonisolated` because the measurement helpers run on the audio thread.
    public nonisolated static let floorDecibels: Float = -60

    private var engine: AVAudioEngine?

    public init() {
        isAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    deinit {
        // Tear down without hopping actors; the engine is safe to stop here.
        engine?.stop()
    }

    // MARK: - Lifecycle

    /// Starts metering, requesting microphone access the first time.
    public func start() {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isAuthorized = true
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAuthorized = granted
                    if granted {
                        self.startEngine()
                    } else {
                        self.unavailableReason = "Microphone access denied"
                    }
                }
            }
        case .denied, .restricted:
            isAuthorized = false
            unavailableReason = "Microphone access denied"
        @unknown default:
            unavailableReason = "Microphone access unavailable"
        }
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
        decibels = nil
    }

    /// Rebuilds the tap after the default input device changed. `AVAudioEngine`
    /// binds to the device that was current when it started, so it has to be
    /// torn down and recreated rather than simply left running.
    public func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    // MARK: - Engine

    private func startEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // A device that reports zero channels cannot be tapped; installing a tap
        // anyway raises an exception inside CoreAudio.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            unavailableReason = "This input device provides no signal"
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let measured = Self.peakLevel(of: buffer)
            Task { @MainActor in
                self?.apply(measured)
            }
        }

        do {
            try engine.start()
            self.engine = engine
            isRunning = true
            unavailableReason = nil
        } catch {
            unavailableReason = "Could not start metering"
            self.engine = nil
        }
    }

    /// Smooths the published level so the bar does not flicker.
    ///
    /// Attack is fast and release is slow, the standard behaviour of a level
    /// meter: peaks should register instantly, then fall back gradually.
    private func apply(_ measured: Float) {
        let normalised = Self.normalise(decibels: measured)
        level = normalised > level
            ? normalised
            : level * 0.82 + normalised * 0.18
        decibels = measured
    }

    // MARK: - Measurement

    /// Peak amplitude of a buffer, in dBFS.
    nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return floorDecibels }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return floorDecibels }

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                peak = max(peak, abs(samples[frame]))
            }
        }
        guard peak > 0 else { return floorDecibels }
        return max(20 * log10(peak), floorDecibels)
    }

    /// Maps dBFS onto 0...1 for the meter bar.
    nonisolated static func normalise(decibels: Float) -> Float {
        guard decibels > floorDecibels else { return 0 }
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }
}
