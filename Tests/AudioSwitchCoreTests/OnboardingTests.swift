import XCTest

@testable import AudioSwitchCore

/// Welcome-guide gating and paging, plus the persisted "seen" version.
final class OnboardingTests: XCTestCase {

    func testShowsWhenNeverSeen() {
        XCTAssertTrue(Onboarding.shouldShow(seenVersion: 0))
    }

    func testHiddenOnceCurrentVersionSeen() {
        XCTAssertFalse(Onboarding.shouldShow(seenVersion: Onboarding.currentVersion))
    }

    func testShowsAgainWhenGuideVersionIsBumped() {
        XCTAssertTrue(Onboarding.shouldShow(seenVersion: Onboarding.currentVersion - 1))
    }

    func testPagingClampsAtBothEnds() {
        XCTAssertEqual(Onboarding.page(0, step: -1), 0)
        XCTAssertEqual(Onboarding.page(0, step: 1), 1)
        XCTAssertEqual(Onboarding.page(Onboarding.pageCount - 1, step: 1), Onboarding.pageCount - 1)
    }

    func testSeenVersionPersistsAndDefaultsToZero() {
        let suite = "com.iamzifei.audioswitch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.onboardingSeenVersion, 0)
        prefs.onboardingSeenVersion = Onboarding.currentVersion
        XCTAssertEqual(Preferences(defaults: defaults).onboardingSeenVersion, Onboarding.currentVersion)
    }

    /// Every page's strings and screenshot must exist in every language.
    func testEveryGuidePageHasStringsAndScreenshot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AudioSwitch/Resources")
        for n in 1...Onboarding.pageCount {
            for lang in ["en", "zh-Hans", "zh-Hant"] {
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("onboarding-\(n)-\(lang).jpg").path), "\(lang) screenshot \(n)")
                let text = try String(contentsOf: root.appendingPathComponent("\(lang).lproj/Localizable.strings"), encoding: .utf8)
                XCTAssertTrue(text.contains("\"onboarding.title.\(n)\""), "\(lang) title \(n)")
                XCTAssertTrue(text.contains("\"onboarding.body.\(n)\""), "\(lang) body \(n)")
            }
        }
    }

    /// A truly fresh install has no defaults at all and must show the guide.
    func testFreshInstallWithNoDefaultsShowsGuide() {
        let suite = "com.iamzifei.audioswitch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: "onboardingSeenVersion"))
        XCTAssertTrue(Onboarding.shouldShow(seenVersion: Preferences(defaults: defaults).onboardingSeenVersion))
        // The language setting must also start on System.
        XCTAssertEqual(Preferences(defaults: defaults).languageCode, "system")
    }

    /// Upgrade from 1.5.0, which stored version 1: nothing new to show in 1.5.1.
    func testUpgradeFromEarlierGuideVersionDoesNotReshow() {
        XCTAssertFalse(Onboarding.shouldShow(seenVersion: 1))
    }

    func testSuggestedLanguage() {
        let cases: [([String], String)] = [
            (["zh-Hant-TW"], "zh-Hant"), (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"),
            (["zh-Hant"], "zh-Hant"), (["zh-Hant-HK", "en"], "zh-Hant"),
            (["zh-Hans-CN"], "zh-Hans"), (["zh-CN"], "zh-Hans"), (["zh"], "zh-Hans"),
            (["zh-SG"], "zh-Hans"), (["en-AU"], "en"), (["ja-JP"], "en"),
            (["en-US", "zh-Hans"], "en"), ([], "en"),
        ]
        for (preferred, expected) in cases {
            XCTAssertEqual(Onboarding.suggestedLanguageCode(preferred: preferred), expected, "\(preferred)")
        }
    }
}
