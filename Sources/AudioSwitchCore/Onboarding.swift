import Foundation

/// When to show the first-run welcome guide, and how its pages step.
/// Pure logic; the window lives in the app target.
public enum Onboarding {
    /// Bump when the guide gains content worth showing to existing users
    /// again. Version 1 = the first guide (AudioSwitch 1.5.0).
    public static let currentVersion = 1

    /// Pages: menu bar, output, input + microphone access, options + settings.
    public static let pageCount = 4

    /// `seenVersion` is the last guide version the user was shown (0 when the
    /// key is missing: a fresh install, or an upgrade from before 1.5.0).
    public static func shouldShow(seenVersion: Int) -> Bool {
        seenVersion < currentVersion
    }

    /// Moves `step` pages from `index`, never past either end.
    public static func page(_ index: Int, step: Int) -> Int {
        min(max(0, index + step), pageCount - 1)
    }

    /// Which shipped interface language best matches the system's preferred
    /// languages: "zh-Hant", "zh-Hans" or "en".
    ///
    /// Only the first (most preferred) entry counts. Traditional Chinese covers
    /// an explicit Hant script and the Taiwan / Hong Kong / Macau regions; any
    /// other Chinese is Simplified; everything else falls back to English.
    public static func suggestedLanguageCode(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let first = preferred.first?.lowercased() else { return "en" }
        let parts = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard parts.first == "zh" else { return "en" }
        if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") {
            return "zh-Hant"
        }
        return "zh-Hans"
    }
}
