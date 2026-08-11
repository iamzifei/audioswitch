import AppKit

/// Deep links into System Settings.
enum SystemSettings {
    /// Opens System Settings → Sound, the same destination as the system volume
    /// menu's "Sound Settings…" item.
    static func openSound() {
        // Ventura and later address panes by extension bundle identifier.
        let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}

/// Version metadata shown at the bottom of the panel.
enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "AudioSwitch \(short) (Build \(build))"
    }
}
