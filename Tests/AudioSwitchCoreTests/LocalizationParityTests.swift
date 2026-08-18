import XCTest

/// Guards the three `.lproj` files against drifting apart.
///
/// Every visible string is looked up by key, so a key added to English alone
/// does not fail the build — it shows the raw key to Chinese users instead.
/// Comparing the files here catches that at test time.
final class LocalizationParityTests: XCTestCase {

    private let languages = ["en", "zh-Hans", "zh-Hant"]

    private var resourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AudioSwitchCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/AudioSwitch/Resources", isDirectory: true)
    }

    private func entries(of language: String) throws -> [String: String] {
        let url = resourcesRoot
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" = \"")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \";"))
            found[key] = value
        }
        return found
    }

    func testEveryLanguageHasEveryKey() throws {
        let english = try entries(of: "en")
        XCTAssertGreaterThan(english.count, 30, "English strings file looks truncated")

        for language in languages where language != "en" {
            let translated = try entries(of: language)
            XCTAssertEqual(
                Set(english.keys).subtracting(translated.keys), [],
                "\(language) is missing keys English has"
            )
            XCTAssertEqual(
                Set(translated.keys).subtracting(english.keys), [],
                "\(language) has keys English does not"
            )
        }
    }

    /// Real format specifiers, ignoring `%%`.
    ///
    /// Counting raw `%` characters would flag the Chinese strings, which write
    /// `%d%%` where English writes "%d percent" — an escaped literal, not an
    /// argument, and a difference the translation is allowed to have.
    private func specifiers(in value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(%|[0-9]+\\$)?[@dfsu]")
        let range = NSRange(value.startIndex..., in: value)
        return pattern.matches(in: value, range: range).compactMap {
            guard let r = Range($0.range, in: value) else { return nil }
            let token = String(value[r])
            return token.hasPrefix("%%") ? nil : token
        }
    }

    func testFormatPlaceholdersMatchEnglish() throws {
        // A translation that drops a %@ crashes String(format:) at the call
        // site rather than merely reading oddly.
        let english = try entries(of: "en")
        for language in languages where language != "en" {
            let translated = try entries(of: language)
            for (key, value) in english {
                XCTAssertEqual(
                    specifiers(in: translated[key] ?? "").count,
                    specifiers(in: value).count,
                    "\(language): \(key) has a different number of format placeholders"
                )
            }
        }
    }

    func testTheSupportLinkIsOfferedInEveryLanguage() throws {
        for language in languages {
            XCTAssertNotNil(try entries(of: language)["about.support"], "\(language) cannot show the Ko-fi button")
        }
    }
}
