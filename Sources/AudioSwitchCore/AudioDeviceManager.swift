import Combine
import CoreAudio
import Foundation

/// Observable source of truth for the audio device list, the current system
/// defaults, and their volume state.
///
/// The manager keeps itself in sync with CoreAudio by registering property
/// listeners for the device list changing (plug / unplug), the defaults
/// changing, and the active devices' volume / mute changing. That means the
/// panel stays correct even when the user changes things in System Settings,
/// presses the volume keys, or connects AirPods.
@MainActor
public final class AudioDeviceManager: ObservableObject {

    /// Every device that may become a system default, both directions mixed.
    /// Use `devices(for:)` to get the list for one direction.
    @Published public private(set) var devices: [AudioDevice] = []

    @Published public private(set) var defaultOutputID: AudioObjectID?
    @Published public private(set) var defaultInputID: AudioObjectID?

    /// Volume / mute of the current default output and input device.
    @Published public private(set) var outputVolume: VolumeState = .unavailable
    @Published public private(set) var inputVolume: VolumeState = .unavailable

    /// Set when a switch attempt fails, so the UI can tell the user something
    /// went wrong instead of silently doing nothing.
    @Published public private(set) var lastError: String?

    /// When locking is on for a direction, any attempt by another app to change
    /// that default device is undone. This is the fix for conferencing apps
    /// that grab the microphone when they launch.
    @Published public var isOutputLocked: Bool {
        didSet {
            preferences.isOutputLocked = isOutputLocked
            if isOutputLocked { lockedOutputUID = defaultDevice(for: .output)?.uid }
        }
    }

    @Published public var isInputLocked: Bool {
        didSet {
            preferences.isInputLocked = isInputLocked
            if isInputLocked { lockedInputUID = defaultDevice(for: .input)?.uid }
        }
    }

    /// Hard-off switch for the microphone.
    ///
    /// Mutes the current default input device — and re-mutes whichever device
    /// becomes default later — so no application can pick up audio. This is a
    /// system-wide effect, not just a change to what this app listens to.
    @Published public var isInputDisabled: Bool {
        didSet {
            preferences.isInputDisabled = isInputDisabled
            applyInputDisabled()
        }
    }

    /// Gain captured before zeroing it, for devices with no mute switch.
    private var inputVolumeBeforeDisabling: Float?

    /// Locks are stored by UID rather than object ID so that they survive a
    /// device being unplugged and reconnected.
    private var lockedOutputUID: String? {
        didSet { preferences.lockedOutputUID = lockedOutputUID }
    }

    private var lockedInputUID: String? {
        didSet { preferences.lockedInputUID = lockedInputUID }
    }

    private let preferences: Preferences

    /// Listener blocks are retained so they can be unregistered later.
    /// CoreAudio does not keep the block alive for us.
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init(preferences: Preferences = .standard) {
        self.preferences = preferences
        self.isOutputLocked = preferences.isOutputLocked
        self.isInputLocked = preferences.isInputLocked
        self.lockedOutputUID = preferences.lockedOutputUID
        self.lockedInputUID = preferences.lockedInputUID
        self.isInputDisabled = preferences.isInputDisabled

        refresh()
        installSystemListeners()
        installVolumeListeners()

        // A device may have been locked while it was disconnected; if it is
        // back now, restore it immediately.
        enforceLocks()
        // Re-assert a persisted mic-off across launches and reboots.
        applyInputDisabled()
    }

    deinit {
        let system = systemListeners
        let devices = deviceListeners
        for (address, block) in system {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioProperty.systemObject, &address, DispatchQueue.main, block
            )
        }
        for (deviceID, address, block) in devices {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
    }

    // MARK: - Reading state

    public func devices(for direction: AudioDirection) -> [AudioDevice] {
        devices.devices(for: direction)
    }

    public func defaultDevice(for direction: AudioDirection) -> AudioDevice? {
        let id = direction == .output ? defaultOutputID : defaultInputID
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    public func isDefault(_ device: AudioDevice, for direction: AudioDirection) -> Bool {
        switch direction {
        case .output: return device.id == defaultOutputID
        case .input: return device.id == defaultInputID
        }
    }

    public func volume(for direction: AudioDirection) -> VolumeState {
        direction == .output ? outputVolume : inputVolume
    }

    public func isLocked(_ direction: AudioDirection) -> Bool {
        direction == .output ? isOutputLocked : isInputLocked
    }

    public func setLocked(_ locked: Bool, for direction: AudioDirection) {
        switch direction {
        case .output: isOutputLocked = locked
        case .input: isInputLocked = locked
        }
    }

    /// Re-reads the whole device list, both defaults, and both volumes.
    public func refresh() {
        devices = Self.readDevices()
        defaultOutputID = Self.readDefaultDeviceID(for: .output)
        defaultInputID = Self.readDefaultDeviceID(for: .input)
        refreshVolumes()
    }

    public func refreshVolumes() {
        outputVolume = defaultOutputID.map {
            VolumeController.state(deviceID: $0, direction: .output)
        } ?? .unavailable
        inputVolume = defaultInputID.map {
            VolumeController.state(deviceID: $0, direction: .input)
        } ?? .unavailable
    }

    // MARK: - Switching

    /// Makes `device` the system default for `direction`.
    ///
    /// For output we also move `kAudioHardwarePropertyDefaultSystemOutputDevice`
    /// — the channel used for alerts and UI sounds. macOS tracks it separately,
    /// and leaving it behind is why some switcher utilities keep playing alert
    /// sounds through the old speakers.
    @discardableResult
    public func setDefault(_ device: AudioDevice, for direction: AudioDirection) -> Bool {
        guard device.supports(direction) else {
            lastError = "\(device.name) cannot be the default \(direction.rawValue) device."
            return false
        }

        let status = CoreAudioProperty.setValue(
            CoreAudioProperty.systemObject,
            CoreAudioProperty.address(direction.defaultDeviceSelector),
            device.id
        )
        guard status == noErr else {
            lastError = "Could not switch \(direction.rawValue) to \(device.name) (OSStatus \(status))."
            return false
        }

        if direction == .output {
            // Best-effort: some virtual devices refuse to become the system
            // alert device. Not worth failing the whole switch over.
            CoreAudioProperty.setValue(
                CoreAudioProperty.systemObject,
                CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
                device.id
            )
        }

        // Picking a device by hand re-arms the lock onto that device, otherwise
        // the lock would immediately drag the user back to the old one.
        switch direction {
        case .output: if isOutputLocked { lockedOutputUID = device.uid }
        case .input: if isInputLocked { lockedInputUID = device.uid }
        }

        lastError = nil
        // The property listener also fires, but updating now keeps the
        // checkmark from lagging behind the click.
        refresh()
        installVolumeListeners()
        return true
    }

    /// Advances to the next device in `direction`, wrapping around at the end.
    @discardableResult
    public func selectNextDevice(for direction: AudioDirection) -> AudioDevice? {
        let candidates = devices(for: direction)
        guard !candidates.isEmpty else { return nil }

        let currentID = direction == .output ? defaultOutputID : defaultInputID
        let currentIndex = candidates.firstIndex { $0.id == currentID }
        let nextIndex = ((currentIndex ?? -1) + 1) % candidates.count
        let next = candidates[nextIndex]
        return setDefault(next, for: direction) ? next : nil
    }

    // MARK: - Volume

    public func setVolume(_ scalar: Float, for direction: AudioDirection) {
        guard let deviceID = direction == .output ? defaultOutputID : defaultInputID else { return }
        VolumeController.setVolume(scalar, deviceID: deviceID, direction: direction)
        refreshVolumes()
    }

    public func setMuted(_ muted: Bool, for direction: AudioDirection) {
        guard let deviceID = direction == .output ? defaultOutputID : defaultInputID else { return }
        VolumeController.setMuted(muted, deviceID: deviceID, direction: direction)
        refreshVolumes()
    }

    public func toggleMute(for direction: AudioDirection) {
        setMuted(!volume(for: direction).isMuted, for: direction)
    }

    // MARK: - Disabling the microphone

    /// Applies the mic-off state to the current default input device.
    ///
    /// Muting is the mechanism, because CoreAudio has no way to switch a device
    /// off. Devices that expose no mute switch get their gain zeroed instead,
    /// with the previous level remembered so re-enabling restores it — silently
    /// doing nothing would be the worst outcome for a privacy control.
    private func applyInputDisabled() {
        guard let deviceID = defaultInputID else { return }

        if isInputDisabled {
            if !VolumeController.setMuted(true, deviceID: deviceID, direction: .input) {
                let current = VolumeController.state(deviceID: deviceID, direction: .input)
                if current.isSettable {
                    inputVolumeBeforeDisabling = current.scalar
                    VolumeController.setVolume(0, deviceID: deviceID, direction: .input)
                } else {
                    lastError = "This microphone cannot be switched off from software."
                }
            }
        } else {
            VolumeController.setMuted(false, deviceID: deviceID, direction: .input)
            if let restore = inputVolumeBeforeDisabling {
                VolumeController.setVolume(restore, deviceID: deviceID, direction: .input)
                inputVolumeBeforeDisabling = nil
            }
        }
        refreshVolumes()
    }

    // MARK: - Locking

    /// If a direction is locked and something moved its default device away
    /// from the locked one, move it back.
    private func enforceLocks() {
        for direction in AudioDirection.allCases {
            guard isLocked(direction),
                  let lockedUID = direction == .output ? lockedOutputUID : lockedInputUID,
                  let target = devices.first(where: { $0.uid == lockedUID }),
                  target.supports(direction)
            else { continue }

            let currentID = direction == .output ? defaultOutputID : defaultInputID
            guard currentID != target.id else { continue }

            // Write directly rather than going through setDefault(), which would
            // re-arm the lock onto whatever is currently selected.
            CoreAudioProperty.setValue(
                CoreAudioProperty.systemObject,
                CoreAudioProperty.address(direction.defaultDeviceSelector),
                target.id
            )
            if direction == .output {
                CoreAudioProperty.setValue(
                    CoreAudioProperty.systemObject,
                    CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
                    target.id
                )
            }
            defaultOutputID = Self.readDefaultDeviceID(for: .output)
            defaultInputID = Self.readDefaultDeviceID(for: .input)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func readDevices() -> [AudioDevice] {
        let ids = CoreAudioProperty.array(
            CoreAudioProperty.systemObject,
            CoreAudioProperty.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID.self
        )

        return ids.compactMap { id -> AudioDevice? in
            let inputChannels = CoreAudioProperty.channelCount(
                deviceID: id, scope: AudioDirection.input.scope
            )
            let outputChannels = CoreAudioProperty.channelCount(
                deviceID: id, scope: AudioDirection.output.scope
            )
            guard inputChannels > 0 || outputChannels > 0 else { return nil }

            let name = CoreAudioProperty.string(
                id, CoreAudioProperty.address(kAudioObjectPropertyName)
            ) ?? "Unknown Device"
            let uid = CoreAudioProperty.string(
                id, CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ) ?? "device-\(id)"
            let transportType = CoreAudioProperty.value(
                id, CoreAudioProperty.address(kAudioDevicePropertyTransportType),
                as: UInt32.self
            ) ?? 0

            let device = AudioDevice(
                id: id,
                uid: uid,
                name: name,
                transport: AudioTransport(transportType: transportType),
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                canBeDefaultInput: canBeDefault(deviceID: id, direction: .input),
                canBeDefaultOutput: canBeDefault(deviceID: id, direction: .output),
                outputDataSource: dataSource(deviceID: id, direction: .output),
                inputDataSource: dataSource(deviceID: id, direction: .input)
            )
            // Drop devices the system would not offer in either direction.
            guard device.supports(.input) || device.supports(.output) else { return nil }
            return device
        }
    }

    /// Whether CoreAudio allows this device to become the default for a
    /// direction — the same test System Settings → Sound applies.
    private static func canBeDefault(deviceID: AudioObjectID, direction: AudioDirection) -> Bool {
        let address = CoreAudioProperty.address(
            kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope
        )
        // Devices that do not implement the property at all are treated as
        // selectable, which matches how the system handles older drivers.
        guard VolumeController.hasProperty(deviceID: deviceID, address: address) else { return true }
        return (CoreAudioProperty.value(deviceID, address, as: UInt32.self) ?? 0) != 0
    }

    /// Reads the device's data source for a direction, used to pick an icon.
    private static func dataSource(
        deviceID: AudioObjectID,
        direction: AudioDirection
    ) -> AudioDataSource? {
        let address = CoreAudioProperty.address(
            kAudioDevicePropertyDataSource, scope: direction.scope
        )
        guard VolumeController.hasProperty(deviceID: deviceID, address: address),
              let raw = CoreAudioProperty.value(deviceID, address, as: UInt32.self)
        else { return nil }
        return AudioDataSource(rawValue: raw)
    }

    private static func readDefaultDeviceID(for direction: AudioDirection) -> AudioObjectID? {
        let id = CoreAudioProperty.value(
            CoreAudioProperty.systemObject,
            CoreAudioProperty.address(direction.defaultDeviceSelector),
            as: AudioObjectID.self
        )
        guard let id, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Subscribes to the system properties that can invalidate our state.
    private func installSystemListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ]

        for selector in selectors {
            let address = CoreAudioProperty.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refresh()
                    // Volume listeners are per device, so they must follow the
                    // default device when it changes.
                    self.installVolumeListeners()
                    self.enforceLocks()
                    // A newly connected or newly selected microphone must not
                    // come up live while the mic-off switch is on.
                    self.applyInputDisabled()
                }
            }
            var mutableAddress = address
            if AudioObjectAddPropertyListenerBlock(
                CoreAudioProperty.systemObject, &mutableAddress, DispatchQueue.main, block
            ) == noErr {
                systemListeners.append((address, block))
            }
        }
    }

    /// (Re)subscribes to volume and mute changes on the two active devices, so
    /// the slider and the menu bar icon follow the volume keys and other apps.
    private func installVolumeListeners() {
        for (deviceID, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()

        for direction in AudioDirection.allCases {
            guard let deviceID = direction == .output ? defaultOutputID : defaultInputID else {
                continue
            }
            // Watch the main element plus the first two channels: which one
            // carries the control depends on the device.
            let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
            let selectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]

            for selector in selectors {
                for element in elements {
                    let address = CoreAudioProperty.address(
                        selector, scope: direction.scope, element: element
                    )
                    guard VolumeController.hasProperty(deviceID: deviceID, address: address) else {
                        continue
                    }
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.refreshVolumes() }
                    }
                    var mutableAddress = address
                    if AudioObjectAddPropertyListenerBlock(
                        deviceID, &mutableAddress, DispatchQueue.main, block
                    ) == noErr {
                        deviceListeners.append((deviceID, address, block))
                    }
                }
            }
        }
    }
}
