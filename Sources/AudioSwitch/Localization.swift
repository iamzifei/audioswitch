import AudioSwitchCore
import Foundation
import SwiftUI

/// Languages the interface can be shown in.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese
    case traditionalChinese

    var id: String { rawValue }

    /// Directory name of the matching `.lproj` bundle.
    var localeCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        }
    }

    var titleKey: String {
        switch self {
        case .system: return "language.system"
        case .english: return "language.english"
        case .simplifiedChinese: return "language.simplified_chinese"
        case .traditionalChinese: return "language.traditional_chinese"
        }
    }
}

/// Supplies localized strings and lets the user override the interface language
/// at runtime.
///
/// Rather than relying on `NSLocalizedString`, which resolves against the app's
/// bundle once at launch, strings are read from the `.lproj` bundle for the
/// selected language. That is what makes switching languages take effect
/// immediately instead of after a restart.
@MainActor
final class Localization: ObservableObject {

    @Published private(set) var language: AppLanguage
    private var bundle: Bundle
    private let preferences: Preferences

    init(preferences: Preferences = .standard) {
        self.preferences = preferences
        let stored = AppLanguage(rawValue: preferences.languageCode) ?? .system
        self.language = stored
        self.bundle = Self.bundle(for: stored)
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        self.bundle = Self.bundle(for: language)
        preferences.languageCode = language.rawValue
    }

    /// Looks up a key in the active language.
    func callAsFunction(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: callAsFunction(key), arguments: arguments)
    }

    /// The bundle SwiftPM emits the `.lproj` directories into.
    ///
    /// Deliberately *not* `Bundle.module`. SwiftPM generates that accessor to
    /// look in exactly two places — `Bundle.main.bundleURL/<name>.bundle` and
    /// the absolute path of the build directory it was compiled in — and to
    /// call `fatalError` when neither exists. `build.sh` puts the bundle in
    /// `Contents/Resources`, which is neither, so every copy of the app worked
    /// only on machines that still had the original build directory: the
    /// developer's. Shipped builds crashed on launch. Resolving it ourselves
    /// covers both layouts and, more importantly, never traps.
    static let resourceBundle: Bundle = {
        let name = "AudioSwitch_AudioSwitch.bundle"
        let candidates = [
            // Where build.sh puts it inside the .app.
            Bundle.main.resourceURL?.appendingPathComponent(name),
            // Where SwiftPM expects it, i.e. next to the binary under `swift run`.
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Last resort: the app's own resources. Strings then fall back to their
        // keys, which is ugly but is a running app rather than a crashed one.
        return .main
    }()

    /// Resolves the bundle to read strings from.
    ///
    /// `.system` follows the user's language preferences, falling back through
    /// the localizations the app actually ships.
    private static func bundle(for language: AppLanguage) -> Bundle {
        let resources = resourceBundle

        guard let code = language.localeCode else {
            // Match the system's preferred language against what we ship;
            // CFBundle already resolves this for the default case.
            return resources
        }

        // SwiftPM lowercases .lproj directory names when it assembles its
        // resource bundle: "zh-Hans.lproj" in the source tree ships as
        // "zh-hans.lproj". Looking up only the canonical spelling fails and
        // falls back to English without any error.
        for candidate in [code, code.lowercased()] {
            if let path = resources.path(forResource: candidate, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
        }
        return resources
    }
}
