import CoreAudio
import XCTest

@testable import AudioSwitchCore

/// Tests for the pure model logic: direction filtering, sorting, and transport
/// mapping. These do not touch real hardware so they are deterministic.
final class AudioDeviceTests: XCTestCase {

    private func makeDevice(
        id: AudioObjectID = 1,
        uid: String = "uid",
        name: String = "Device",
        transport: AudioTransport = .unknown,
        inputChannels: Int = 0,
        outputChannels: Int = 0,
        canBeDefaultInput: Bool = true,
        canBeDefaultOutput: Bool = true
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            canBeDefaultInput: canBeDefaultInput,
            canBeDefaultOutput: canBeDefaultOutput
        )
    }

    // MARK: - Direction support

    func testOutputOnlyDeviceSupportsOnlyOutput() {
        let speakers = makeDevice(outputChannels: 2)
        XCTAssertTrue(speakers.supports(.output))
        XCTAssertFalse(speakers.supports(.input))
    }

    func testInputOnlyDeviceSupportsOnlyInput() {
        let microphone = makeDevice(inputChannels: 1)
        XCTAssertTrue(microphone.supports(.input))
        XCTAssertFalse(microphone.supports(.output))
    }

    func testDuplexDeviceSupportsBothDirections() {
        // e.g. a USB audio interface or AirPods in headset mode
        let interface = makeDevice(inputChannels: 2, outputChannels: 2)
        XCTAssertTrue(interface.supports(.input))
        XCTAssertTrue(interface.supports(.output))
    }

    // MARK: - Filtering and sorting

    func testDevicesForDirectionFiltersByChannelCount() {
        let devices = [
            makeDevice(id: 1, uid: "a", name: "Speakers", outputChannels: 2),
            makeDevice(id: 2, uid: "b", name: "Microphone", inputChannels: 1),
            makeDevice(id: 3, uid: "c", name: "Interface", inputChannels: 2, outputChannels: 2),
        ]

        XCTAssertEqual(devices.devices(for: .output).map(\.name), ["Interface", "Speakers"])
        XCTAssertEqual(devices.devices(for: .input).map(\.name), ["Interface", "Microphone"])
    }

    func testDevicesAreSortedCaseInsensitively() {
        let devices = [
            makeDevice(id: 1, uid: "a", name: "zoom Audio", outputChannels: 2),
            makeDevice(id: 2, uid: "b", name: "AirPods Pro", outputChannels: 2),
            makeDevice(id: 3, uid: "c", name: "MacBook Speakers", outputChannels: 2),
        ]

        XCTAssertEqual(
            devices.devices(for: .output).map(\.name),
            ["AirPods Pro", "MacBook Speakers", "zoom Audio"]
        )
    }

    func testIdenticallyNamedDevicesAreOrderedByUID() {
        // Two identical USB interfaces report the same product name; the UID is
        // what keeps their order stable across refreshes.
        let devices = [
            makeDevice(id: 1, uid: "uid-b", name: "Scarlett 2i2", outputChannels: 2),
            makeDevice(id: 2, uid: "uid-a", name: "Scarlett 2i2", outputChannels: 2),
        ]

        XCTAssertEqual(devices.devices(for: .output).map(\.uid), ["uid-a", "uid-b"])
    }

    // MARK: - Parity with System Settings → Sound

    func testDeviceThatCannotBeDefaultIsExcludedEvenWithChannels() {
        // Members of an aggregate device report channels but are not offered by
        // System Settings, because CoreAudio marks them as ineligible.
        let member = makeDevice(
            id: 1, uid: "member", name: "Aggregate Member",
            outputChannels: 2, canBeDefaultOutput: false
        )
        let speakers = makeDevice(id: 2, uid: "speakers", name: "Speakers", outputChannels: 2)

        XCTAssertFalse(member.supports(.output))
        XCTAssertEqual([member, speakers].devices(for: .output).map(\.name), ["Speakers"])
    }

    func testDirectionEligibilityIsIndependentPerDirection() {
        // A device can be a valid microphone but not a valid speaker.
        let device = makeDevice(
            inputChannels: 2, outputChannels: 2,
            canBeDefaultInput: true, canBeDefaultOutput: false
        )
        XCTAssertTrue(device.supports(.input))
        XCTAssertFalse(device.supports(.output))
    }

    func testEmptyListReturnsEmptyForBothDirections() {
        let devices: [AudioDevice] = []
        XCTAssertTrue(devices.devices(for: .output).isEmpty)
        XCTAssertTrue(devices.devices(for: .input).isEmpty)
    }

    // MARK: - Transport mapping

    func testTransportMappingCoversCommonHardware() {
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeHDMI), .displayPort)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeAirPlay), .airPlay)
        XCTAssertEqual(AudioTransport(transportType: kAudioDeviceTransportTypeAggregate), .virtual)
    }

    func testUnrecognisedTransportFallsBackToUnknown() {
        XCTAssertEqual(AudioTransport(transportType: 0), .unknown)
        XCTAssertEqual(AudioTransport(transportType: 0xDEAD_BEEF), .unknown)
    }

    func testSymbolDiffersByDirectionForAmbiguousTransports() {
        // A built-in device is a speaker on the way out and a mic on the way in.
        XCTAssertEqual(AudioTransport.builtIn.symbolName(for: .output), "speaker.wave.2")
        XCTAssertEqual(AudioTransport.builtIn.symbolName(for: .input), "mic")
        // AirPlay is directionally unambiguous, so the symbol stays the same.
        XCTAssertEqual(
            AudioTransport.airPlay.symbolName(for: .output),
            AudioTransport.airPlay.symbolName(for: .input)
        )
    }

    // MARK: - Direction metadata

    func testDirectionMapsToCorrectCoreAudioScope() {
        XCTAssertEqual(AudioDirection.output.scope, kAudioObjectPropertyScopeOutput)
        XCTAssertEqual(AudioDirection.input.scope, kAudioObjectPropertyScopeInput)
    }

    func testDirectionMapsToCorrectDefaultDeviceSelector() {
        XCTAssertEqual(
            AudioDirection.output.defaultDeviceSelector,
            kAudioHardwarePropertyDefaultOutputDevice
        )
        XCTAssertEqual(
            AudioDirection.input.defaultDeviceSelector,
            kAudioHardwarePropertyDefaultInputDevice
        )
    }
}
