import CoreAudio
import XCTest

@testable import AudioSwitchCore

/// Integration tests that talk to the real CoreAudio server on this machine.
///
/// They deliberately avoid changing the user's audio setup: the only write test
/// re-selects the device that is already active, which is a no-op from the
/// user's point of view but still exercises the full write path.
@MainActor
final class AudioDeviceManagerTests: XCTestCase {

    func testEnumeratesAtLeastOneDevice() {
        let manager = AudioDeviceManager()
        // Every Mac has built-in output; if this fails, enumeration is broken.
        XCTAssertFalse(manager.devices.isEmpty, "CoreAudio reported no audio devices at all")
    }

    func testEveryDeviceHasNameAndUID() {
        let manager = AudioDeviceManager()
        for device in manager.devices {
            XCTAssertFalse(device.name.isEmpty, "Device \(device.id) has an empty name")
            XCTAssertFalse(device.uid.isEmpty, "Device \(device.id) has an empty UID")
        }
    }

    func testEveryListedDeviceHasChannelsInSomeDirection() {
        let manager = AudioDeviceManager()
        for device in manager.devices {
            XCTAssertTrue(
                device.supports(.input) || device.supports(.output),
                "\(device.name) was listed but has no channels in either direction"
            )
        }
    }

    func testDefaultOutputResolvesToAListedDevice() throws {
        let manager = AudioDeviceManager()
        let defaultOutput = try XCTUnwrap(
            manager.defaultDevice(for: .output),
            "No default output device on this machine"
        )
        XCTAssertTrue(defaultOutput.supports(.output))
        XCTAssertTrue(manager.isDefault(defaultOutput, for: .output))
    }

    func testDeviceUIDsAreUnique() {
        let manager = AudioDeviceManager()
        let uids = manager.devices.map(\.uid)
        XCTAssertEqual(Set(uids).count, uids.count, "Duplicate device UIDs: \(uids)")
    }

    func testReselectingTheCurrentDefaultSucceedsAndIsIdempotent() throws {
        let manager = AudioDeviceManager()
        let current = try XCTUnwrap(manager.defaultDevice(for: .output))

        XCTAssertTrue(manager.setDefault(current, for: .output))
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.defaultOutputID, current.id)
    }

    func testSwitchingToADeviceWithoutChannelsInThatDirectionIsRejected() throws {
        let manager = AudioDeviceManager()
        // Find an output-only device and try to make it the default input.
        let outputOnly = manager.devices.first { $0.supports(.output) && !$0.supports(.input) }
        let device = try XCTUnwrap(outputOnly, "No output-only device available to test with")

        XCTAssertFalse(manager.setDefault(device, for: .input))
        XCTAssertNotNil(manager.lastError, "A rejected switch must report an error")
        // The rejected write must not have touched the actual system default.
        XCTAssertNotEqual(manager.defaultInputID, device.id)
    }

    // MARK: - Volume

    func testReportedDecibelsNeverContradictTheSliderPosition() {
        // Regression guard. Some drivers return a garbage value from
        // kAudioDevicePropertyVolumeDecibels — an Audioengine 2+ at 12.5%
        // volume reported 1.38e-30 dB, which displayed as "0 dB" next to a
        // slider sitting near the bottom. Decibels are now derived from the
        // scalar, so a quiet device can never claim to be at full level.
        let manager = AudioDeviceManager()
        for direction in AudioDirection.allCases {
            let state = manager.volume(for: direction)
            guard let decibels = state.decibels else { continue }

            XCTAssertTrue(decibels.isFinite, "\(direction) reported a non-finite dB value")
            // 0 dB conventionally means full scale, so it must not appear while
            // the slider is down near the bottom of its travel.
            if state.scalar < 0.5 {
                XCTAssertLessThan(
                    decibels, 0,
                    "\(direction) is at \(state.scalar) scalar but claims \(decibels) dB"
                )
            }
        }
    }

    func testVolumeStateMatchesTheDeviceItDescribes() throws {
        let manager = AudioDeviceManager()
        let output = try XCTUnwrap(manager.defaultDevice(for: .output))
        let direct = VolumeController.state(deviceID: output.id, direction: .output)

        XCTAssertEqual(manager.outputVolume.scalar, direct.scalar, accuracy: 0.001)
        XCTAssertEqual(manager.outputVolume.isMuted, direct.isMuted)
    }

    func testVolumeScalarStaysInRange() {
        let manager = AudioDeviceManager()
        for direction in AudioDirection.allCases {
            let scalar = manager.volume(for: direction).scalar
            XCTAssertGreaterThanOrEqual(scalar, 0)
            XCTAssertLessThanOrEqual(scalar, 1)
        }
    }

    func testRefreshIsStable() {
        let manager = AudioDeviceManager()
        let firstPass = manager.devices.map(\.uid)
        manager.refresh()
        let secondPass = manager.devices.map(\.uid)
        // Ordering is by name, so two back-to-back refreshes must agree.
        XCTAssertEqual(firstPass, secondPass)
    }
}
