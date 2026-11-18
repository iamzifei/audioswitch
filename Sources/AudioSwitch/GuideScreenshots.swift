import AppKit
import AudioSwitchCore
import SwiftUI

/// Renders the four welcome-guide screenshots, in every language, from the
/// real `DevicePanel` and a fixed demo device list.
///
/// Nothing here touches the screen: the panel is hosted in a window that is
/// never ordered front, and its view hierarchy is drawn into a bitmap with
/// `cacheDisplay`. (`ImageRenderer` cannot be used: it draws sliders, switches
/// and pop-up buttons as placeholder icons.)
@MainActor
enum GuideScreenshots {

    /// Canvas for one screenshot, in points. 2:1 like the guide's image frame.
    static let canvas = CGSize(width: 500, height: 250)

    /// Which part of the panel each screenshot shows: the panel's y offset
    /// (points scrolled up from its top) and whether the menu bar is drawn.
    private struct Shot { let offset: CGFloat; let showsMenuBar: Bool }
    private static let shots = [
        Shot(offset: 0, showsMenuBar: true),     // 1: attached to the menu bar
        Shot(offset: 0, showsMenuBar: false),    // 2: output card
        Shot(offset: 0, showsMenuBar: false),    // 3: input card
        Shot(offset: 0, showsMenuBar: false),    // 4: options + footer
    ]

    // MARK: demo data

    private static func device(_ id: UInt32, _ name: String, _ transport: AudioTransport,
                               out: Int, inp: Int,
                               outSource: AudioDataSource? = nil) -> AudioDevice {
        AudioDevice(id: id, uid: "demo-\(id)", name: name, transport: transport,
                    inputChannels: inp, outputChannels: out,
                    canBeDefaultInput: inp > 0, canBeDefaultOutput: out > 0,
                    outputDataSource: outSource)
    }

    private static let demoDevices: [AudioDevice] = [
        device(1, "Audioengine 2+", .usb, out: 2, inp: 0),
        device(2, "BlackHole 2ch", .virtual, out: 2, inp: 2),
        device(3, "Gemoo Speaker", .usb, out: 2, inp: 2),
        device(4, "M28U", .displayPort, out: 2, inp: 0),
        device(5, "MacBook Pro Speakers", .builtIn, out: 2, inp: 0, outSource: .internalSpeaker),
        device(6, "VX1622-4K", .displayPort, out: 2, inp: 0),
        device(7, "iPhone 15 Pro Microphone", .unknown, out: 0, inp: 1),
        device(8, "MacBook Pro Microphone", .builtIn, out: 0, inp: 1),
        device(9, "Wireless Mic Rx", .usb, out: 0, inp: 1),
    ]

    private static func panel(language: AppLanguage, scratch: Preferences) -> some View {
        let l10n = Localization(preferences: scratch)
        l10n.setLanguage(language)
        let manager = AudioDeviceManager(
            demoDevices: demoDevices, defaultOutputID: 1, defaultInputID: 9,
            outputVolume: VolumeState(scalar: 0.2, decibels: -38, isMuted: false,
                                      isSettable: true, isMuteSupported: true),
            inputVolume: VolumeState(scalar: 0.62, decibels: -14, isMuted: false,
                                     isSettable: true, isMuteSupported: false),
            preferences: scratch)
        return DevicePanel(
            manager: manager,
            levelMeter: InputLevelMeter(demoLevel: 0.22, decibels: -46),
            l10n: l10n, updater: Updater(), onSelect: {}, scrollable: false)
    }

    // MARK: scene

    private struct Scene: View {
        let shot: Shot
        let content: AnyView
        let panelTop: CGFloat

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.25, green: 0.36, blue: 0.70),
                                        Color(red: 0.08, green: 0.12, blue: 0.36)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if shot.showsMenuBar {
                    // A bare menu bar with AudioSwitch's own icon in its
                    // pressed state, so the popover reads as attached to it.
                    Rectangle().fill(Color.black.opacity(0.35)).frame(height: 24)
                        .frame(width: GuideScreenshots.canvas.width,
                               height: GuideScreenshots.canvas.height, alignment: .top)
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.top, 2)
                        .frame(width: GuideScreenshots.canvas.width,
                               height: GuideScreenshots.canvas.height, alignment: .top)
                }
                // Popover body: soft grey container with a pointer on top.
                VStack(spacing: 0) {
                    if shot.showsMenuBar {
                        Triangle().fill(Color(white: 0.30)).frame(width: 16, height: 8)
                    }
                    content
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(white: 0.30))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(width: GuideScreenshots.canvas.width,
                       height: GuideScreenshots.canvas.height, alignment: .top)
                .offset(y: panelTop)
            }
            .frame(width: GuideScreenshots.canvas.width, height: GuideScreenshots.canvas.height)
            .clipped()
            .environment(\.colorScheme, .dark)
        }
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    /// A window that reports itself key and main without ever being shown, so
    /// controls draw in their active (tinted) appearance.
    private final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    /// Draws `view` into a PNG at 2x.
    private static func png(of view: some View, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = OffscreenWindow(contentRect: host.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Give SwiftUI a few turns to build the AppKit-backed controls.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size   // 2 pixels per point
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Where, in panel points, each section starts. Filled in by measuring a
    /// full-height render; see `sectionTops`.
    static var sectionTops: [CGFloat] = [0, 2, 243, 486]

    static func renderAll(to dir: String) {
        _ = NSApplication.shared
        let scratch = Preferences(defaults: UserDefaults(suiteName: "audioswitch.guideshots") ?? .standard)
        for language in AppLanguage.allCases where language != .system {
            // Full panel, for checking section positions by eye.
            let fullSize = CGSize(width: 320, height: 760)
            if let data = png(of: panel(language: language, scratch: scratch)
                                .environment(\.colorScheme, .dark)
                                .frame(width: 320, height: 760, alignment: .top)
                                .background(Color(white: 0.30)), size: fullSize) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/full-\(language.localeCode ?? "x").png"))
            }
            for (i, shot) in shots.enumerated() {
                let top = (shot.showsMenuBar ? 34 : 8) - sectionTops[i]
                let scene = Scene(shot: shot, content: AnyView(panel(language: language, scratch: scratch)),
                                  panelTop: top)
                if let data = png(of: scene, size: canvas) {
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/shot-\(language.localeCode ?? "x")-\(i + 1).png"))
                }
            }
        }
    }
}
