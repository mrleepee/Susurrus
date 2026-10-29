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

    public init() {
        self.devicesProvider = {
            AudioProcessor.getAudioDevices().map {
                AudioInputDevice(id: $0.id, name: $0.name)
            }
        }
        self.defaultInputProvider = { Self.systemDefaultInputID() }
    }

    /// Test-only initialiser accepting a fixed device list.
    internal init(
        devicesProvider: @escaping () -> [AudioInputDevice],
        defaultInputProvider: @escaping () -> UInt32? = { nil }
    ) {
        self.devicesProvider = devicesProvider
        self.defaultInputProvider = defaultInputProvider
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

    /// The input to record from when the user hasn't picked one: whatever
    /// macOS currently has selected as its input (System Settings > Sound >
    /// Input), read fresh at each session start. A Bluetooth speaker or
    /// headset that becomes the default when it connects is used, matching
    /// what the user sees in Settings.
    ///
    /// Returns `nil` only if Core Audio reports no usable default input.
    public func sessionDefaultInput() -> AudioInputDevice? {
        guard let defaultID = defaultInputProvider() else { return nil }
        return devicesProvider().first(where: { $0.id == defaultID })
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
}
