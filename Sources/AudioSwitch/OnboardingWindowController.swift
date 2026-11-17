import AppKit
import AudioSwitchCore
import SwiftUI

/// One page of the welcome guide.
struct GuidePage {
    let symbol: String      // SF Symbol shown beside the title
    let title: String
    let body: String
    /// Bundled screenshot, nil when running unbundled.
    let image: NSImage?
}

final class OnboardingModel: ObservableObject {
    @Published var page = 0
}

/// First-run welcome guide: a few short pages, each with a screenshot of the
/// real panel. Shown once per `Onboarding.currentVersion` and reopenable from
/// the panel footer.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// "Open the panel" on the last page.
    var onOpenPanel: (() -> Void)?

    private let l10n: Localization
    private let preferences: Preferences
    private let model = OnboardingModel()
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(l10n: Localization, preferences: Preferences = .standard) {
        self.l10n = l10n
        self.preferences = preferences
    }

    /// Called at launch: shows the guide only if this version hasn't been seen.
    func showIfNeeded() {
        guard Onboarding.shouldShow(seenVersion: preferences.onboardingSeenVersion) else { return }
        show()
    }

    func show() {
        // Already open: bring it forward and keep the page.
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Marked seen as soon as it appears: closing early means "not now",
        // and it stays one click away in the panel footer.
        preferences.onboardingSeenVersion = Onboarding.currentVersion
        model.page = 0

        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.delegate = self
            window = w
        }
        window?.title = l10n("onboarding.window_title")
        window?.contentView = NSHostingView(rootView: OnboardingView(
            model: model,
            l10n: l10n,
            onFinish: { [weak self] in self?.finish() },
            onClose: { [weak self] in self?.window?.close() }
        ))
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func finish() {
        window?.close()
        // Let the guide go away before the popover takes focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.onOpenPanel?()
        }
    }

    // Left/Right = page, Return = next (or finish), Esc = close.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { self?.handleKey(code) ?? false }
            return handled ? nil : event
        }
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ code: UInt16) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        switch code {
        case 123: model.page = Onboarding.page(model.page, step: -1)
        case 124: model.page = Onboarding.page(model.page, step: 1)
        case 36, 76:
            if model.page == Onboarding.pageCount - 1 { finish() }
            else { model.page = Onboarding.page(model.page, step: 1) }
        case 53: window.close()
        default: return false
        }
        return true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: content

    private static let symbols = ["menubar.rectangle", "speaker.wave.2", "mic", "switch.2"]

    static func image(_ n: Int) -> NSImage? {
        Localization.resourceBundle.url(forResource: "onboarding-\(n)", withExtension: "jpg")
            .flatMap(NSImage.init(contentsOf:))
    }

    /// Built per render so a language change is picked up immediately.
    static func pages(_ l10n: Localization) -> [GuidePage] {
        (1...Onboarding.pageCount).map { n in
            GuidePage(symbol: symbols[n - 1],
                      title: l10n("onboarding.title.\(n)"),
                      body: l10n("onboarding.body.\(n)"),
                      image: image(n))
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var l10n: Localization
    let onFinish: () -> Void
    let onClose: () -> Void

    private var pages: [GuidePage] { OnboardingWindowController.pages(l10n) }
    private var isLast: Bool { model.page == Onboarding.pageCount - 1 }

    var body: some View {
        let pages = pages
        let page = pages[min(model.page, pages.count - 1)]
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // Fixed-height frame so text does not jump between pages.
                Group {
                    if let image = page.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.imageHeight)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .accessibilityHidden(true)

                HStack(spacing: 10) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(page.title)
                        .font(.system(size: 22, weight: .bold))
                }
                Text(page.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Divider()
            HStack {
                if !isLast {
                    Button(l10n("onboarding.skip"), action: onClose)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<Onboarding.pageCount, id: \.self) { i in
                        Circle()
                            .fill(i == model.page ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 7, height: 7)
                            .onTapGesture { model.page = i }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n("onboarding.page_of", model.page + 1, Onboarding.pageCount))
                Spacer()
                if model.page > 0 {
                    Button(l10n("onboarding.back")) { model.page = Onboarding.page(model.page, step: -1) }
                }
                if isLast {
                    Button(l10n("onboarding.done"), action: onFinish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(l10n("onboarding.next")) { model.page = Onboarding.page(model.page, step: 1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// 576 pt content width (640 - 2x32) at the screenshots' 2:1 ratio.
    static let imageHeight: CGFloat = 288
    static let size = CGSize(width: 640, height: 510)
}
