import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater.
///
/// `SPUStandardUpdaterController` provides the whole update experience — the
/// update-available prompt, download progress, and install-and-relaunch — and
/// runs background checks according to the `SUEnableAutomaticChecks` and
/// `SUScheduledCheckInterval` keys in Info.plist. The feed URL and the EdDSA
/// public key that authenticates it come from Info.plist too (`SUFeedURL`,
/// `SUPublicEDKey`), so nothing about the update channel is hard-coded here.
///
/// Auto-update only works from a proper signed `.app` bundle. When the binary
/// runs unbundled — `swift run`, or the render/snapshot modes — there is no
/// bundle for Sparkle to replace, so it is skipped entirely.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleIdentifier != nil else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Whether a manual check can run right now; drives the button's state.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// User-initiated check. Unlike the scheduled one, this always shows UI —
    /// including "you're up to date", which is what someone pressing the button
    /// is asking to be told.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
