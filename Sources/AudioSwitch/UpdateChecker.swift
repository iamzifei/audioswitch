import AudioSwitchCore
import Foundation
import SwiftUI

/// Where the app lives, used by the About panel and the update check.
enum AppMetadata {
    static let repositoryOwner = "iamzifei"
    static let repositoryName = "audioswitch"
    static let author = "James"

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)")!
    }

    static var releasesURL: URL {
        repositoryURL.appendingPathComponent("releases/latest")
    }

    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

/// Checks GitHub Releases for a newer version.
///
/// Deliberately not Sparkle: the app is ad-hoc signed rather than Developer ID
/// signed and notarised, so an in-place silent update would install a build
/// Gatekeeper then refuses to launch. Instead this reports what is available
/// and hands the user to the release page, which is honest about the one manual
/// step a non-notarised app requires.
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed
    }

    @Published private(set) var state: State = .idle

    private let preferences: Preferences
    private let session: URLSession

    init(preferences: Preferences = .standard, session: URLSession = .shared) {
        self.preferences = preferences
        self.session = session
    }

    /// Runs a check at most once a day unless `force` is set, so opening the
    /// panel does not hit the network every time.
    func check(force: Bool = false) {
        guard state != .checking else { return }
        if !force, let last = preferences.lastUpdateCheck,
           Date().timeIntervalSince(last) < 86_400 {
            return
        }

        state = .checking
        Task { [weak self] in
            guard let self else { return }
            let result = await Self.fetchLatestVersion(session: self.session)
            self.preferences.lastUpdateCheck = Date()

            guard let latest = result else {
                self.state = .failed
                return
            }
            self.state = Self.isNewer(latest, than: AppMetadata.shortVersion)
                ? .available(version: latest)
                : .upToDate
        }
    }

    private static func fetchLatestVersion(session: URLSession) async -> String? {
        var request = URLRequest(url: AppMetadata.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }

        // Releases are tagged "v1.2.0"; the leading v is not part of the version.
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric component-wise comparison, so 1.10.0 sorts above 1.9.0 —
    /// a plain string compare gets that backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
