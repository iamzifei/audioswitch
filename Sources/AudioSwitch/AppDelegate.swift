import AppKit
import AudioSwitchCore
import Combine
import SwiftUI

/// Owns the menu bar item and the popover that lists the audio devices.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let manager = AudioDeviceManager()
    private let levelMeter = InputLevelMeter()
    private let localization = Localization()
    private let updater = Updater()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []

    /// Point size for the menu bar glyph.
    ///
    /// Measured against the system volume icon captured side by side: at 16pt
    /// ours rendered noticeably larger than the system's, 14.5pt matches it.
    private static let menuBarSymbolPointSize: CGFloat = 14.5

    /// Width every rendered glyph is padded to, so the item never changes size.
    ///
    /// Without this the status item resizes as the icon changes, which shifts
    /// it — and every icon to its left — sideways. Computed once from the
    /// widest glyph the app can display.
    private lazy var fixedIconWidth: CGFloat = {
        MenuBarIcon.allSymbolNames.compactMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.symbolConfiguration)?
                .size.width
        }.max() ?? 22
    }()

    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: menuBarSymbolPointSize, weight: .regular, scale: .medium
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()

        // Subscribe to the published values, NOT to objectWillChange.
        //
        // objectWillChange fires *before* the property is updated, so reading
        // the manager from that callback yields the previous volume — the icon
        // would always lag one change behind, which looks like it only reacts
        // to large jumps.
        manager.$outputVolume
            .removeDuplicates()
            .sink { [weak self] state in self?.updateStatusItem(with: state) }
            .store(in: &cancellables)

        // The device name is part of the tooltip and the optional title, so the
        // icon also needs refreshing when the default output device changes.
        manager.$defaultOutputID
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(with: self.manager.outputVolume)
            }
            .store(in: &cancellables)

        // The icon is derived from the device itself, and a device can change
        // underneath a stable ID: plugging into the built-in headphone jack
        // keeps the same output device but flips its data source from speakers
        // to headphones, which is exactly the case the icon must catch.
        manager.$devices
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(with: self.manager.outputVolume)
            }
            .store(in: &cancellables)

        // AVAudioEngine binds to whichever device was default when it started,
        // so the meter has to be rebuilt when the input device changes.
        manager.$defaultInputID
            .removeDuplicates()
            .sink { [weak self] _ in self?.levelMeter.restartIfRunning() }
            .store(in: &cancellables)

        // Disabling the microphone must also release this app's own tap —
        // otherwise the recording indicator would stay lit while the panel is
        // open, which is exactly what the switch is meant to prevent.
        manager.$isInputDisabled
            .removeDuplicates()
            .sink { [weak self] disabled in
                guard let self else { return }
                if disabled {
                    self.levelMeter.stop()
                } else if self.popover?.isShown == true {
                    self.levelMeter.start()
                }
            }
            .store(in: &cancellables)

        // Development aid: open the panel straight away so it can be captured
        // without synthesising a click on the status item.
        if ProcessInfo.processInfo.environment["AUDIOSWITCH_SHOW_PANEL"] == "1" {
            // The status item's window is not laid out yet at launch, so the
            // popover would anchor to nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.imagePosition = .imageOnly
            button.toolTip = localization("menubar.tooltip")
            button.target = self
            button.action = #selector(statusItemClicked)
            // Ask for right-clicks as well; the default is left-click only.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
        updateStatusItem(with: manager.outputVolume)
    }

    /// Builds the menu bar glyph for a volume state.
    ///
    /// The symbol follows the default output device: headphones get their own
    /// glyph, anything else gets the speaker. For the speaker this uses SF
    /// Symbols' variable-value rendering: `speaker.wave.3` is one glyph whose
    /// arcs light up progressively with a 0...1 value, which is how the system
    /// volume icon works. That gives finer steps than swapping between
    /// wave.1/2/3 and, because the glyph's bounding box never changes, the item
    /// stays put instead of shifting as the level changes.
    ///
    /// The result is a template image, so macOS tints it automatically for
    /// light mode, dark mode, and the tinted menu bar styles — no colour of our
    /// own is ever baked in.
    private func statusIcon(for state: VolumeState) -> NSImage? {
        let device = manager.defaultDevice(for: .output)
        let symbol = MenuBarIcon.symbolName(for: device, volume: state)
        let description = accessibilityDescription(for: state)

        // Only the speaker symbols have a variable form; the headphone glyphs
        // are fixed drawings, so there is no level to pass them.
        let image = MenuBarIcon.isVariable(symbol)
            ? NSImage(
                systemSymbolName: symbol,
                variableValue: state.symbolVariableValue,
                accessibilityDescription: description
            )
            : NSImage(systemSymbolName: symbol, accessibilityDescription: description)

        let base = image?.withSymbolConfiguration(Self.symbolConfiguration)

        guard let base else { return nil }
        return paddedToFixedWidth(base)
    }

    /// Centres a glyph on a canvas of constant width so the status item's size
    /// never changes between states.
    private func paddedToFixedWidth(_ image: NSImage) -> NSImage {
        let width = max(fixedIconWidth, image.size.width)
        let canvas = NSImage(size: NSSize(width: width, height: image.size.height))
        canvas.lockFocus()
        image.draw(
            at: NSPoint(x: ((width - image.size.width) / 2).rounded(), y: 0),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        canvas.unlockFocus()
        // Template rendering must be re-applied: it does not survive being
        // composited onto a new image.
        canvas.isTemplate = true
        return canvas
    }

    private func accessibilityDescription(for state: VolumeState) -> String {
        let device = manager.defaultDevice(for: .output)?.name ?? localization("menubar.no_device")
        if state.isMuted { return localization("menubar.muted", device) }
        return localization("menubar.output", device, Int((state.scalar * 100).rounded()))
    }

    private func updateStatusItem(with state: VolumeState) {
        guard let button = statusItem?.button else { return }
        button.image = statusIcon(for: state)

        // Optional device name next to the icon, off by default to keep the
        // menu bar uncluttered.
        if Preferences.standard.showsDeviceNameInMenuBar,
           let name = manager.defaultDevice(for: .output)?.name {
            button.imagePosition = .imageLeading
            button.title = " \(name)"
            button.font = .menuBarFont(ofSize: 0)
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    @objc private func statusItemClicked() {
        // Right-click is a shortcut for "just give me the next output device"
        // without having to aim at a menu row.
        if NSApp.currentEvent?.type == .rightMouseUp {
            manager.selectNextDevice(for: .output)
            updateStatusItem(with: manager.outputVolume)
            return
        }
        togglePopover()
    }

    // MARK: - Popover

    private func setUpPopover() {
        let popover = NSPopover()
        // .transient closes the panel as soon as the user clicks elsewhere,
        // which is what people expect from a menu bar item.
        // A transient popover closes as soon as anything else takes focus,
        // which is what people expect — but it also makes the panel impossible
        // to screenshot, since the capture tool itself steals focus. The env
        // var keeps it open for UI verification.
        popover.behavior = ProcessInfo.processInfo.environment["AUDIOSWITCH_STICKY_PANEL"] == "1"
            ? .applicationDefined
            : .transient
        popover.animates = false
        // Needed to know when a transient popover closes by itself, so the
        // microphone tap can be released.
        popover.delegate = self

        let panel = DevicePanel(
            manager: manager,
            levelMeter: levelMeter,
            l10n: localization,
            updater: updater,
            onSelect: { [weak self] in self?.closePopover() }
        )
        let hosting = NSHostingController(rootView: panel)
        // Let the SwiftUI layout drive the popover size, so the panel grows and
        // shrinks with the number of connected devices.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        self.popover = popover
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // Activate *before* showing. An accessory app is inactive by default,
        // and a popover shown from an inactive app comes up without key focus:
        // SwiftUI then draws every control in its greyed-out inactive
        // appearance — sliders lose their tint, the meter loses its colour —
        // until the next click activates the app. Ordering this first is what
        // makes the first open look the same as every subsequent one.
        NSApp.activate(ignoringOtherApps: true)

        // Re-read devices and levels right before showing: something may have
        // changed while the popover was closed.
        manager.refresh()
        // Only hold the microphone while the panel is visible — otherwise the
        // app would keep the system's recording indicator lit permanently —
        // and never while the mic-off switch is on.
        if !manager.isInputDisabled {
            levelMeter.start()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Belt and braces: make the popover's own window key so its controls
        // render active and the keyboard shortcuts reach it.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - Popover lifecycle

extension AppDelegate: NSPopoverDelegate {
    /// Fires for every close path — clicking the icon again, clicking away, or
    /// picking a device — so the level meter never keeps running unseen.
    func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            levelMeter.stop()
        }
    }
}
