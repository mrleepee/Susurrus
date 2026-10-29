import CoreAudio
import Foundation
@preconcurrency import WhisperKit

/// Default enumerator backed by WhisperKit's `AudioProcessor.getAudioDevices()`,
/// which talks to Core Audio to list input devices.
public final class AudioDeviceService: AudioDeviceEnumerating, @unchecked Sendable {

    /// Optional injection point for tests — supply a closure that returns
    /// `AudioInputDevice` values directly instead of calling Core Audio.
    private let devicesProvider: () -> [AudioInputDevice]
    private let defaultInputProvider: () -> UInt32?
    private let isBluetoothProvider: (UInt32) -> Bool
    private let isBuiltInProvider: (UInt32) -> Bool

    public init() {
        self.devicesProvider = {
            AudioProcessor.getAudioDevices().map {
                AudioInputDevice(id: $0.id, name: $0.name)
            }
        }
        self.defaultInputProvider = { Self.systemDefaultInputID() }
        self.isBluetoothProvider = { id in
            let transport = Self.transportType(of: id)
            return transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        self.isBuiltInProvider = { Self.transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// Test-only initialiser accepting a fixed device list.
    internal init(
        devicesProvider: @escaping () -> [AudioInputDevice],
        defaultInputProvider: @escaping () -> UInt32? = { nil },
        isBluetooth: @escaping (UInt32) -> Bool = { _ in false },
        isBuiltIn: @escaping (UInt32) -> Bool = { _ in false }
    ) {
        self.devicesProvider = devicesProvider
        self.defaultInputProvider = defaultInputProvider
        self.isBluetoothProvider = isBluetooth
        self.isBuiltInProvider = isBuiltIn
    }

    public func availableInputs() -> [AudioInputDevice] {
        devicesProvider()
    }

    public func resolve(preferredName: String?) -> AudioDeviceResolution {
        guard let preferredName, !preferredName.isEmpty else {
            return .systemDefault
        }
        if let match = devicesProvider().first(where: { $0.name == preferredName }) {
            return .specific(id: match.id, name: match.name)
        }
        return .unavailable(requestedName: preferredName)
    }

    /// The input to record from when the user hasn't picked one: the system
    /// default, except that a Bluetooth default is passed over for the
    /// built-in mic. Connecting a Bluetooth speaker or headset can make its
    /// microphone the system default input without the user noticing —
    /// switching output back in the Sound menu doesn't undo it — and that
    /// mic is across the room (near-silent capture) and forces the device
    /// into its low-quality call profile. Users who want a Bluetooth mic can
    /// still select it explicitly in Preferences.
    ///
    /// Returns `nil` only if Core Audio reports no usable default input.
    public func sessionDefaultInput() -> AudioInputDevice? {
        let devices = devicesProvider()
        guard let defaultID = defaultInputProvider(),
              let current = devices.first(where: { $0.id == defaultID }) else {
            return nil
        }
        guard isBluetoothProvider(current.id),
              let builtIn = devices.first(where: { isBuiltInProvider($0.id) }) else {
            return current
        }
        return builtIn
    }

    // MARK: - Core Audio

    public static func systemDefaultInputID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func transportType(of deviceID: UInt32) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }
}
