import AppKit
import SwiftUI

/// The About screen, shown in place of the device list.
///
/// A separate page rather than a separate window: menu bar apps have no window
/// to attach one to, and pushing it inside the popover keeps everything in the
/// same place the user already has open.
struct AboutPage: View {
    @ObservedObject var l10n: Localization
    @ObservedObject var updater: Updater
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 14) {
                icon

                VStack(spacing: 4) {
                    Text(l10n("about.title"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(l10n("about.tagline"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 3) {
                    Text(l10n("about.version", AppMetadata.shortVersion, AppMetadata.buildNumber))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(l10n("about.author", AppMetadata.author))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    LinkButton(
                        title: l10n("about.github"),
                        symbol: "chevron.left.forwardslash.chevron.right"
                    ) {
                        NSWorkspace.shared.open(AppMetadata.repositoryURL)
                    }

                    LinkButton(
                        title: l10n("command.check_for_updates"),
                        symbol: "arrow.triangle.2.circlepath"
                    ) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(l10n("about.back"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// The real app icon, so the About screen matches what is in the Dock and
    /// Finder rather than a stand-in glyph.
    private var icon: some View {
        Group {
            if let appIcon = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "speaker.wave.3.fill")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 72, height: 72)
    }

}

/// A pill-shaped secondary button, matching the footer's visual weight.
private struct LinkButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered ? AnyShapeStyle(.selection.opacity(0.6)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
