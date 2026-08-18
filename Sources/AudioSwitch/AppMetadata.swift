import Foundation

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

    /// Where the app asks for support. One address for all three apps, so a
    /// visitor arriving from any of them lands on the same page.
    static var supportURL: URL {
        URL(string: "https://ko-fi.com/iamzifei")!
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
