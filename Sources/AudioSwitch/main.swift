import AppKit
import AudioSwitchCore
import SwiftUI

// Release guard: `AUDIOSWITCH_SMOKE_TEST=1` prints where the localization
// resources were resolved from, checks that a string in every shipped language
// actually loads, and exits.
//
// It exists because a resource bundle that resolves on the build machine and
// nowhere else is invisible until someone downloads the app: v1.2.0 and v1.3.0
// both shipped a bundle no downloader could find, and crashed on launch.
// build.sh runs this against the assembled .app and refuses to package a build
// whose resources resolve to anything outside it.
if ProcessInfo.processInfo.environment["AUDIOSWITCH_SMOKE_TEST"] == "1" {
    MainActor.assumeIsolated {
        let bundle = Localization.resourceBundle
        print("resources: \(bundle.bundleURL.path)")

        var failed = false
        // A throwaway defaults suite: switching languages persists the choice,
        // and a smoke test must not rewrite the user's own setting.
        let scratch = Preferences(
            defaults: UserDefaults(suiteName: "audioswitch.smoketest") ?? .standard
        )
        for language in AppLanguage.allCases {
            let l10n = Localization(preferences: scratch)
            l10n.setLanguage(language)
            // Every language ships this key; getting the key back means the
            // lookup fell through to an empty bundle.
            let value = l10n("menubar.tooltip")
            print("  \(language.rawValue): \(value)")
            if value == "menubar.tooltip" { failed = true }
        }
        exit(failed ? 1 : 0)
    }
}

// Development aid: `AUDIOSWITCH_RENDER_PANEL=<path>` renders the panel to a PNG
// and exits without ever showing a menu bar item.
//
// It exists because the panel is a transient popover, which closes the moment
// any screenshot tool takes focus — so there is otherwise no way to inspect a
// UI change without doing it by hand.
if let renderPath = ProcessInfo.processInfo.environment["AUDIOSWITCH_RENDER_PANEL"] {
    MainActor.assumeIsolated {
        // Optional AUDIOSWITCH_RENDER_LANG picks the language to render in.
        let l10n = Localization()
        if let code = ProcessInfo.processInfo.environment["AUDIOSWITCH_RENDER_LANG"],
           let language = AppLanguage(rawValue: code) {
            l10n.setLanguage(language)
        }

        // AUDIOSWITCH_RENDER_ABOUT=1 renders the About page instead.
        let showsAbout = ProcessInfo.processInfo.environment["AUDIOSWITCH_RENDER_ABOUT"] == "1"

        let content = ZStack {
            Color(nsColor: .windowBackgroundColor)
            if showsAbout {
                AboutPage(l10n: l10n, updater: Updater(), onBack: {})
                    .frame(width: 320)
            } else {
                DevicePanel(
                    manager: AudioDeviceManager(),
                    levelMeter: InputLevelMeter(),
                    l10n: l10n,
                    updater: Updater(),
                    onSelect: {},
                    scrollable: false
                )
            }
        }
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: renderPath))
        print("rendered \(renderPath)")
    }
    exit(0)
}

// Entry point.
//
// The app is built around AppKit's NSStatusItem rather than SwiftUI's
// MenuBarExtra: MenuBarExtra silently fails to register a status item in this
// configuration (verified on macOS 26 — the process runs but no status bar
// window is ever created). NSStatusItem is the API every established menu bar
// utility uses and it gives us direct control over click handling.
//
// SwiftUI is still used for the popover's contents via NSHostingController.
let application = NSApplication.shared

// Top-level code runs on the main thread before the run loop starts, so
// constructing the main-actor-isolated delegate here is safe.
// The global `let` matters: NSApplication.delegate is a weak reference, and a
// locally scoped delegate would be deallocated immediately.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate

// .accessory = no Dock icon, no app switcher entry, menu bar only.
// This mirrors LSUIElement in Info.plist and keeps the behaviour correct even
// when the binary is launched directly rather than through the bundle.
application.setActivationPolicy(.accessory)
application.run()
