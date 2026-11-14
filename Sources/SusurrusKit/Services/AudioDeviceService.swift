import CoreAudio
import Foundation
@preconcurrency import WhisperKit

/// Default enumerator backed by WhisperKit's `AudioProcessor.getAudioDevices()`,
/// which talks to Core Audio to list input devices.
public final class AudioDeviceService: AudioDeviceEnumerating, @unchecked Sendable {

    /// Optional injection point for tests — supply a closure that returns
    /// `AudioInputDevice` values directly instead of calling Core Audio.
    private let devicesProvider: () -> [AudioInputDevice]
    private let isBuiltInProvider: (UInt32) -> Bool
    private let defaultInputProvider: () -> UInt32?

    /// UserDefaults key for the Settings override: record from whatever
    /// macOS has selected as its input instead of the Studio Display /
    /// built-in rule.
    public static let useSystemDefaultInputKey = "useSystemDefaultInput"

    public init() {
        self.devicesProvider = {
            AudioProcessor.getAudioDevices().map {
                AudioInputDevice(id: $0.id, name: $0.name)
            }
        }
        self.isBuiltInProvider = { Self.transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn }
        self.defaultInputProvider = { Self.systemDefaultInputID() }
    }

    /// Test-only initialiser accepting a fixed device list.
    internal init(
        devicesProvider: @escaping () -> [AudioInputDevice],
        isBuiltIn: @escaping (UInt32) -> Bool = { _ in false },
        defaultInputProvider: @escaping () -> UInt32? = { nil }
    ) {
        self.devicesProvider = devicesProvider
        self.isBuiltInProvider = isBuiltIn
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

    /// The microphone dictation records from. Only two are ever used: the
    /// Studio Display's mic when the display is connected, otherwise the Mac's
    /// built-in mic. Whatever macOS has selected as its input is ignored, so a
    /// Bluetooth speaker or headset that grabs the default input when it
    /// connects (and drops into its low-quality call profile) is never used.
    ///
    /// With `useSystemDefault` (the Settings override) it is instead whatever
    /// macOS has selected in System Settings > Sound > Input, Bluetooth
    /// included.
    ///
    /// Returns `nil` only if the chosen microphone is not present.
    public func dictationInput(useSystemDefault: Bool = false) -> AudioInputDevice? {
        let devices = devicesProvider()
        if useSystemDefault {
            guard let defaultID = defaultInputProvider() else { return nil }
            return devices.first(where: { $0.id == defaultID })
        }
        if let studio = devices.first(where: { Self.isStudioDisplay($0.name) }) {
            return studio
        }
        return devices.first(where: { isBuiltInProvider($0.id) })
    }

    static func isStudioDisplay(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Studio Display")
    }

    // MARK: - Core Audio

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
