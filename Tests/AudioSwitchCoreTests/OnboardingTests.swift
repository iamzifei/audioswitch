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
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("onboarding-\(n).jpg").path))
            for lang in ["en", "zh-Hans", "zh-Hant"] {
                let text = try String(contentsOf: root.appendingPathComponent("\(lang).lproj/Localizable.strings"), encoding: .utf8)
                XCTAssertTrue(text.contains("\"onboarding.title.\(n)\""), "\(lang) title \(n)")
                XCTAssertTrue(text.contains("\"onboarding.body.\(n)\""), "\(lang) body \(n)")
            }
        }
    }
}
