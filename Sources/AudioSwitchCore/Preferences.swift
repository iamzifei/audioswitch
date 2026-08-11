import Foundation
import ServiceManagement

/// Persisted user settings, backed by `UserDefaults`.
///
/// Injectable so tests can run against an isolated suite instead of the real
/// app defaults.
public final class Preferences: @unchecked Sendable {

    public static let standard = Preferences(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let isOutputLocked = "isOutputLocked"
        static let isInputLocked = "isInputLocked"
        static let lockedOutputUID = "lockedOutputUID"
        static let lockedInputUID = "lockedInputUID"
        static let showsDeviceNameInMenuBar = "showsDeviceNameInMenuBar"
        static let isInputDisabled = "isInputDisabled"
        static let languageCode = "languageCode"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    /// When the update check last completed, so the panel does not hit the
    /// network every time it opens.
    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// Selected interface language, or "system" to follow the OS.
    public var languageCode: String {
        get { defaults.string(forKey: Key.languageCode) ?? "system" }
        set { defaults.set(newValue, forKey: Key.languageCode) }
    }

    /// Whether the microphone is held disabled. Persisted so the machine comes
    /// back with the mic still off after a reboot — a privacy switch that
    /// silently reset itself would be worse than not having one.
    public var isInputDisabled: Bool {
        get { defaults.bool(forKey: Key.isInputDisabled) }
        set { defaults.set(newValue, forKey: Key.isInputDisabled) }
    }

    public var isOutputLocked: Bool {
        get { defaults.bool(forKey: Key.isOutputLocked) }
        set { defaults.set(newValue, forKey: Key.isOutputLocked) }
    }

    public var isInputLocked: Bool {
        get { defaults.bool(forKey: Key.isInputLocked) }
        set { defaults.set(newValue, forKey: Key.isInputLocked) }
    }

    public var lockedOutputUID: String? {
        get { defaults.string(forKey: Key.lockedOutputUID) }
        set { defaults.set(newValue, forKey: Key.lockedOutputUID) }
    }

    public var lockedInputUID: String? {
        get { defaults.string(forKey: Key.lockedInputUID) }
        set { defaults.set(newValue, forKey: Key.lockedInputUID) }
    }

    /// Off by default: the menu bar is scarce real estate and the icon alone
    /// already shows the connection type of the active output.
    public var showsDeviceNameInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showsDeviceNameInMenuBar) }
        set { defaults.set(newValue, forKey: Key.showsDeviceNameInMenuBar) }
    }
}

/// Wraps `SMAppService` so the UI can offer a "Launch at Login" toggle.
///
/// `SMAppService` registers the app bundle with the modern login items API — no
/// helper app and no deprecated `LSSharedFileList` involved. It only works from
/// a real bundle, so it reports `false` when running from the test harness.
public enum LaunchAtLogin {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, or `nil` if the system rejected the change.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled
        } catch {
            return nil
        }
    }
}
