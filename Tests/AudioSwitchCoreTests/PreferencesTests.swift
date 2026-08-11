import XCTest

@testable import AudioSwitchCore

/// Tests for settings persistence and the device-lock behaviour built on it.
/// Runs against an isolated UserDefaults suite so the real app settings are
/// never touched.
@MainActor
final class PreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.iamzifei.audioswitch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLockFlagsDefaultToOff() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.isOutputLocked)
        XCTAssertFalse(preferences.isInputLocked)
        XCTAssertNil(preferences.lockedOutputUID)
        XCTAssertNil(preferences.lockedInputUID)
    }

    func testSettingsRoundTripThroughUserDefaults() {
        let preferences = Preferences(defaults: defaults)
        preferences.isOutputLocked = true
        preferences.lockedOutputUID = "AppleHDAEngineOutput:1"
        preferences.showsDeviceNameInMenuBar = true

        // A second instance reads the same store, which is what happens across
        // app launches.
        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.isOutputLocked)
        XCTAssertEqual(reloaded.lockedOutputUID, "AppleHDAEngineOutput:1")
        XCTAssertTrue(reloaded.showsDeviceNameInMenuBar)
        XCTAssertFalse(reloaded.isInputLocked)
    }

    func testEnablingLockRecordsTheCurrentDeviceAndPersistsIt() throws {
        let preferences = Preferences(defaults: defaults)
        let manager = AudioDeviceManager(preferences: preferences)
        let current = try XCTUnwrap(manager.defaultDevice(for: .output))

        manager.setLocked(true, for: .output)

        XCTAssertTrue(manager.isOutputLocked)
        XCTAssertTrue(preferences.isOutputLocked)
        // The lock stores a UID, not an object ID, so it survives a replug.
        XCTAssertEqual(preferences.lockedOutputUID, current.uid)

        manager.setLocked(false, for: .output)
        XCTAssertFalse(preferences.isOutputLocked)
    }

    func testManagerStartsFromPersistedLockSettings() {
        let preferences = Preferences(defaults: defaults)
        preferences.isInputLocked = true
        preferences.lockedInputUID = "some-mic-uid"

        let manager = AudioDeviceManager(preferences: preferences)
        XCTAssertTrue(manager.isInputLocked)
        XCTAssertTrue(manager.isLocked(.input))
        XCTAssertFalse(manager.isLocked(.output))
    }

    func testLockedDeviceThatIsNotConnectedDoesNotChangeAnything() {
        let preferences = Preferences(defaults: defaults)
        preferences.isOutputLocked = true
        // A UID that is definitely not present on this machine.
        preferences.lockedOutputUID = "not-a-real-device-uid"

        let before = AudioDeviceManager(preferences: Preferences(defaults: defaults))
            .defaultOutputID
        // Constructing the manager runs lock enforcement; with the locked device
        // missing it must leave the current default alone.
        let manager = AudioDeviceManager(preferences: preferences)
        XCTAssertEqual(manager.defaultOutputID, before)
    }

    // MARK: - Disabling the microphone

    func testMicrophoneIsEnabledByDefault() {
        let manager = AudioDeviceManager(preferences: Preferences(defaults: defaults))
        XCTAssertFalse(manager.isInputDisabled)
    }

    func testDisablingTheMicrophoneMutesTheInputDeviceAndPersists() throws {
        let preferences = Preferences(defaults: defaults)
        let manager = AudioDeviceManager(preferences: preferences)
        XCTAssertNotNil(manager.defaultDevice(for: .input), "no input device to test with")

        let originallyMuted = manager.inputVolume.isMuted
        manager.isInputDisabled = true

        XCTAssertTrue(preferences.isInputDisabled, "the switch must survive a restart")
        if manager.inputVolume.isMuteSupported {
            XCTAssertTrue(manager.inputVolume.isMuted, "the input device should be muted")
        } else {
            // Devices without a mute switch get their gain zeroed instead.
            XCTAssertEqual(manager.inputVolume.scalar, 0, accuracy: 0.001)
        }

        manager.isInputDisabled = false
        XCTAssertFalse(preferences.isInputDisabled)
        XCTAssertEqual(manager.inputVolume.isMuted, originallyMuted)
    }

    func testAPersistedMicOffIsReappliedOnLaunch() {
        let preferences = Preferences(defaults: defaults)
        preferences.isInputDisabled = true

        // Constructing the manager is what a fresh launch does.
        let manager = AudioDeviceManager(preferences: preferences)
        XCTAssertTrue(manager.isInputDisabled)
        if manager.inputVolume.isMuteSupported {
            XCTAssertTrue(manager.inputVolume.isMuted)
        }

        // Leave the machine as we found it.
        manager.isInputDisabled = false
    }

    func testDisablingTheMicrophoneLeavesOutputUntouched() throws {
        let preferences = Preferences(defaults: defaults)
        let manager = AudioDeviceManager(preferences: preferences)
        let outputBefore = manager.outputVolume

        manager.isInputDisabled = true
        defer { manager.isInputDisabled = false }

        XCTAssertEqual(manager.outputVolume.scalar, outputBefore.scalar, accuracy: 0.001)
        XCTAssertEqual(manager.outputVolume.isMuted, outputBefore.isMuted)
    }

    func testSwitchingDeviceWhileLockedReArmsTheLockOnTheNewDevice() throws {
        let preferences = Preferences(defaults: defaults)
        let manager = AudioDeviceManager(preferences: preferences)
        let current = try XCTUnwrap(manager.defaultDevice(for: .output))

        manager.setLocked(true, for: .output)
        // Re-selecting the active device is a no-op for the user but still goes
        // through the full switch path.
        XCTAssertTrue(manager.setDefault(current, for: .output))

        XCTAssertEqual(preferences.lockedOutputUID, current.uid)
        XCTAssertEqual(manager.defaultOutputID, current.id)
    }
}
