import Foundation

/// Chooses the glyph shown in the menu bar.
///
/// The icon has to answer two questions at a glance: where the sound is going,
/// and how loud it is. The speaker symbol only answers the second one, and it
/// reads wrong the moment headphones take over — the sound is no longer in the
/// room. So a headphone-class default output replaces the speaker with the same
/// glyph the device gets in the panel (AirPods, AirPods Pro/Max, Beats, or the
/// generic headphones), and everything else keeps the system-style
/// variable-value speaker.
public enum MenuBarIcon {

    /// The glyphs `DeviceIconResolver` uses for things worn on the head.
    ///
    /// Only these take over the menu bar. A HomePod, a monitor or a desk speaker
    /// stays a speaker, because the speaker glyph is already the right picture
    /// for them — swapping in a hi-fi or display glyph would trade a meaningful
    /// icon for a decorative one and lose the volume arcs.
    static let headphoneSymbols: Set<String> = [
        "headphones",
        "airpods",
        "airpods.pro",
        "airpods.max",
        "beats.headphones",
    ]

    /// Every glyph the menu bar can show.
    ///
    /// The status item is padded to the width of the widest entry so it never
    /// resizes — and never nudges its neighbours sideways — when the icon
    /// changes. Sorted so the list is stable between launches.
    public static let allSymbolNames: [String] =
        ["speaker.wave.3.fill", "speaker.slash.fill"] + headphoneSymbols.sorted()

    /// The glyph for the current output device and its volume.
    ///
    /// Silence wins over the device: there is no slashed headphones symbol, and
    /// "you will hear nothing" is the more urgent fact of the two, so a muted or
    /// fully attenuated output keeps the slashed speaker whatever is plugged in.
    public static func symbolName(for device: AudioDevice?, volume: VolumeState) -> String {
        guard !volume.isSilent else { return volume.menuBarSymbolName }

        if let device {
            let symbol = device.symbolName(for: .output)
            if headphoneSymbols.contains(symbol) { return symbol }
        }

        return volume.menuBarSymbolName
    }

    /// Whether the glyph is one of the variable-value speaker symbols, whose
    /// arcs light up with the volume. Headphone glyphs are fixed drawings, so
    /// handing them a variable value would be meaningless.
    public static func isVariable(_ symbolName: String) -> Bool {
        symbolName.hasPrefix("speaker.wave")
    }
}
