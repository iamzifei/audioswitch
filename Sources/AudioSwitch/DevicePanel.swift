import AudioSwitchCore
import SwiftUI

/// The panel shown when the menu bar icon is clicked.
///
/// Laid out in the macOS 26 idiom, the same one Control Center uses: grouped
/// cards floating on the popover's own Liquid Glass material, continuous
/// (squircle) corners throughout, and semantic colours only — so the whole
/// panel adapts to light mode, dark mode, and accent colour changes without a
/// single hard-coded value.
struct DevicePanel: View {
    @ObservedObject var manager: AudioDeviceManager
    @ObservedObject var levelMeter: InputLevelMeter
    @ObservedObject var l10n: Localization
    @ObservedObject var updates: UpdateChecker

    /// Called after the user picks a device, so the host can dismiss the popover.
    let onSelect: () -> Void

    /// False only for offline snapshot rendering: `ImageRenderer` draws nothing
    /// inside a `ScrollView`, so the snapshot mode lays the cards out directly.
    var scrollable: Bool = true

    @State private var isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var isShowingAbout = false

    var body: some View {
        Group {
            if isShowingAbout {
                AboutPage(l10n: l10n, updates: updates) { isShowingAbout = false }
                    .frame(width: Metrics.panelWidth)
            } else {
                mainPage
            }
        }
        .onAppear {
            isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
            updates.check()
        }
    }

    private var mainPage: some View {
        VStack(spacing: Metrics.cardSpacing) {
            if scrollable {
                ScrollView {
                    deviceCards
                }
                // Machines with many virtual devices can list a dozen entries
                // per direction, so the cards scroll rather than running off
                // the bottom of the screen.
                .frame(maxHeight: Metrics.maxScrollHeight)
                .scrollIndicators(.never)
                // Without this the scroll view slices a card off mid-height and
                // its rounded corners turn into a hard square edge. Fading the
                // first and last few points hides the cut.
                .mask(Self.scrollEdgeFade)
            } else {
                deviceCards
            }

            OptionsCard(
                manager: manager,
                l10n: l10n,
                isLaunchAtLoginEnabled: $isLaunchAtLoginEnabled
            )
            .padding(.horizontal, Metrics.panelPadding)

            FooterBar(manager: manager, l10n: l10n) { isShowingAbout = true }
                .padding(.horizontal, Metrics.panelPadding)
                .padding(.bottom, Metrics.panelPadding)

            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Metrics.panelPadding + 4)
                    .padding(.bottom, Metrics.panelPadding)
            }
        }
        .frame(width: Metrics.panelWidth)
        // No background of our own: the popover's system material shows
        // through, which is what makes the cards read as glass.
    }

    private var deviceCards: some View {
        VStack(spacing: Metrics.cardSpacing) {
            ForEach(AudioDirection.allCases, id: \.self) { direction in
                DirectionCard(
                    manager: manager,
                    levelMeter: levelMeter,
                    l10n: l10n,
                    direction: direction,
                    onSelect: onSelect
                )
            }
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, Metrics.panelPadding)
    }

    /// Soft top and bottom edges for the scrolling area.
    ///
    /// The fade is a few points deep and sits inside the content's own padding,
    /// so nothing looks dimmed when the list is short enough not to scroll.
    private static var scrollEdgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.02),
                .init(color: .black, location: 0.98),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Metrics

/// One place for the panel's geometry, so spacing stays consistent.
private enum Metrics {
    static let panelWidth: CGFloat = 320
    static let panelPadding: CGFloat = 10
    static let cardSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 6
    static let cardCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 7
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 6
    static let iconColumnWidth: CGFloat = 18
    static let checkColumnWidth: CGFloat = 13
    static let maxScrollHeight: CGFloat = 460
}

/// A grouped container. macOS 26 leans on soft, translucent cards rather than
/// full-width separators to express grouping.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .overlay(
            // A hairline edge keeps the card legible against a busy wallpaper.
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

// MARK: - Direction card

/// Header, volume, meter, and device list for one direction.
private struct DirectionCard: View {
    @ObservedObject var manager: AudioDeviceManager
    @ObservedObject var levelMeter: InputLevelMeter
    @ObservedObject var l10n: Localization
    let direction: AudioDirection
    let onSelect: () -> Void

    var body: some View {
        let devices = manager.devices(for: direction)

        Card {
            SectionHeader(
                title: l10n(direction == .output ? "section.output" : "section.input"),
                detail: manager.defaultDevice(for: direction)?.name ?? l10n("section.none")
            )

            VolumeRow(manager: manager, l10n: l10n, direction: direction)

            // Live signal from the microphone, directly under its gain slider.
            if direction == .input {
                InputLevelRow(
                    meter: levelMeter,
                    l10n: l10n,
                    isDisabled: manager.isInputDisabled
                )
            }

            Divider()
                .padding(.horizontal, Metrics.rowHorizontalPadding)
                .padding(.vertical, 4)

            if devices.isEmpty {
                Text(l10n(direction == .output
                    ? "section.no_output_devices" : "section.no_input_devices"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
                    .padding(.vertical, 6)
            } else {
                ForEach(devices) { device in
                    DeviceRow(
                        device: device,
                        direction: direction,
                        isSelected: manager.isDefault(device, for: direction)
                    ) {
                        manager.setDefault(device, for: direction)
                        onSelect()
                    }
                }
            }
        }
    }
}

/// Group title on the left, the active device on the right.
private struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
        .padding(.top, 3)
        .padding(.bottom, 5)
    }
}

// MARK: - Volume

/// Mute button, slider, and level readout — the system Sound menu's layout.
private struct VolumeRow: View {
    @ObservedObject var manager: AudioDeviceManager
    @ObservedObject var l10n: Localization
    let direction: AudioDirection

    var body: some View {
        let state = manager.volume(for: direction)

        HStack(spacing: 8) {
            Button {
                manager.toggleMute(for: direction)
            } label: {
                Image(systemName: muteSymbol(for: state))
                    .font(.system(size: 12))
                    .frame(width: Metrics.iconColumnWidth)
                    .foregroundStyle(state.isMuted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!state.isMuteSupported)
            .help(l10n(state.isMuted ? "volume.unmute" : "volume.mute"))

            Slider(
                value: Binding(
                    get: { Double(state.scalar) },
                    set: { manager.setVolume(Float($0), for: direction) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!state.isSettable)

            Text(levelText(for: state))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
                .help(percentText(for: state))
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
        .padding(.vertical, 3)
        .opacity(state.isSettable || state.isMuteSupported ? 1 : 0.4)
    }

    private func muteSymbol(for state: VolumeState) -> String {
        if state.isMuted { return direction == .input ? "mic.slash" : "speaker.slash" }
        return direction == .input ? "mic" : "speaker.wave.2"
    }

    /// Decibels when the device reports them reliably, percentage otherwise.
    /// Both come from the same scalar as the slider, so they cannot disagree
    /// with its position.
    private func levelText(for state: VolumeState) -> String {
        guard state.isSettable else { return "—" }
        if let decibels = state.decibels {
            return String(format: "%.0f dB", decibels)
        }
        return percentText(for: state)
    }

    private func percentText(for state: VolumeState) -> String {
        guard state.isSettable else { return l10n("volume.no_control") }
        return "\(Int((state.scalar * 100).rounded()))%"
    }
}

// MARK: - Input level

/// Segmented meter for the live microphone signal, styled like the input meter
/// in System Settings → Sound.
private struct InputLevelRow: View {
    @ObservedObject var meter: InputLevelMeter
    @ObservedObject var l10n: Localization
    /// True while the mic-off switch is on; the meter shows nothing and the app
    /// does not hold the microphone at all.
    let isDisabled: Bool

    private let segmentCount = 16

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDisabled ? "mic.slash" : "waveform")
                .font(.system(size: 12))
                .frame(width: Metrics.iconColumnWidth)
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let threshold = Float(index + 1) / Float(segmentCount)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color(at: index, isLit: !isDisabled && meter.level >= threshold))
                        .frame(height: 6)
                }
            }
            .animation(.linear(duration: 0.06), value: meter.level)

            Text(levelText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
        .padding(.vertical, 3)
        .opacity(isDisabled ? 0.5 : 1)
        .help(helpText)
    }

    /// Green through the working range, amber near clipping, red at the top —
    /// the convention every audio meter follows.
    private func color(at index: Int, isLit: Bool) -> Color {
        guard isLit else { return Color.primary.opacity(0.1) }
        let position = Double(index) / Double(segmentCount - 1)
        if position > 0.92 { return .red }
        if position > 0.78 { return .orange }
        return .green
    }

    private var levelText: String {
        if isDisabled { return l10n("meter.off") }
        if let reason = meter.unavailableReason, !meter.isRunning {
            return reason.localizedCaseInsensitiveContains("denied")
                ? l10n("meter.no_access") : "—"
        }
        guard let decibels = meter.decibels else { return "—" }
        if decibels <= InputLevelMeter.floorDecibels { return "-∞ dB" }
        return String(format: "%.0f dB", decibels)
    }

    private var helpText: String {
        if isDisabled { return l10n("meter.microphone_disabled") }
        return meter.unavailableReason ?? l10n("meter.live_level")
    }
}

// MARK: - Rows

/// A device row: checkmark column, device icon, name.
private struct DeviceRow: View {
    let device: AudioDevice
    let direction: AudioDirection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: Metrics.checkColumnWidth)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)

                Image(systemName: device.symbolName(for: direction))
                    .font(.system(size: 13))
                    .frame(width: Metrics.iconColumnWidth)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                Text(device.name)
                    .font(.system(size: 13))
                    .fontWeight(isSelected ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)
            }
        }
    }
}

/// An option row with a real switch, which is how macOS 26 presents persistent
/// settings inside a panel — a checkmark reads as a one-shot command.
private struct ToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: Metrics.iconColumnWidth)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
        .padding(.vertical, 4)
    }
}

/// Shared chrome for clickable rows: hit area, hover highlight, continuous corners.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, Metrics.rowHorizontalPadding)
                .padding(.vertical, Metrics.rowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                        .fill(isHovered ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Options and footer

private struct OptionsCard: View {
    @ObservedObject var manager: AudioDeviceManager
    @ObservedObject var l10n: Localization
    @Binding var isLaunchAtLoginEnabled: Bool

    var body: some View {
        Card {
            // A hard off switch for the microphone: mutes it system-wide and
            // stops this app's own metering, so nothing is listening.
            ToggleRow(
                title: l10n("option.disable_microphone"),
                symbol: manager.isInputDisabled ? "mic.slash.fill" : "mic",
                isOn: Binding(
                    get: { manager.isInputDisabled },
                    set: { manager.isInputDisabled = $0 }
                )
            )

            Divider()
                .padding(.horizontal, Metrics.rowHorizontalPadding)
                .padding(.vertical, 3)

            // Locking pins the chosen device so conferencing apps cannot steal
            // it when they launch.
            ToggleRow(
                title: l10n("option.lock_output"),
                symbol: manager.isOutputLocked ? "lock.fill" : "lock.open",
                isOn: Binding(
                    get: { manager.isOutputLocked },
                    set: { manager.setLocked($0, for: .output) }
                )
            )
            ToggleRow(
                title: l10n("option.lock_input"),
                symbol: manager.isInputLocked ? "lock.fill" : "lock.open",
                isOn: Binding(
                    get: { manager.isInputLocked },
                    set: { manager.setLocked($0, for: .input) }
                )
            )
            ToggleRow(
                title: l10n("option.launch_at_login"),
                symbol: "power",
                isOn: Binding(
                    get: { isLaunchAtLoginEnabled },
                    set: { requested in
                        // Reflect what the system actually did rather than what
                        // we asked for: registration can be refused.
                        if let result = LaunchAtLogin.setEnabled(requested) {
                            isLaunchAtLoginEnabled = result
                        } else {
                            isLaunchAtLoginEnabled = LaunchAtLogin.isEnabled
                        }
                    }
                )
            )

            Divider()
                .padding(.horizontal, Metrics.rowHorizontalPadding)
                .padding(.vertical, 3)

            LanguageRow(l10n: l10n)
        }
    }
}

/// Interface language picker. "System" follows the OS setting.
private struct LanguageRow: View {
    @ObservedObject var l10n: Localization

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .frame(width: Metrics.iconColumnWidth)
                .foregroundStyle(.secondary)

            Text(l10n("option.language"))
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { l10n.language },
                set: { l10n.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(l10n(language.titleKey)).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding + 2)
        .padding(.vertical, 4)
    }
}

/// Compact command strip. Keeping these out of the cards marks them as actions
/// rather than state.
private struct FooterBar: View {
    @ObservedObject var manager: AudioDeviceManager
    @ObservedObject var l10n: Localization
    let onAbout: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            FooterButton(title: l10n("command.sound_settings"), symbol: "gearshape") {
                SystemSettings.openSound()
            }
            .keyboardShortcut(",", modifiers: .command)

            FooterButton(title: l10n("command.refresh"), symbol: "arrow.clockwise") {
                manager.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)

            FooterButton(title: l10n("command.about"), symbol: "info.circle", action: onAbout)

            Spacer(minLength: 0)

            FooterButton(title: l10n("command.quit"), symbol: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// Icon-only command button.
///
/// Text labels for four commands do not fit across the panel at 320pt — the
/// longest wrapped onto a second line, and would again in any language with
/// longer words. Icons plus tooltips keep the strip to one line everywhere.
private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
