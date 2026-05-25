import Foundation
@preconcurrency import WhisperKit

/// Default enumerator backed by WhisperKit's `AudioProcessor.getAudioDevices()`,
/// which talks to Core Audio to list input devices.
public final class AudioDeviceService: AudioDeviceEnumerating, @unchecked Sendable {

    /// Optional injection point for tests — supply a closure that returns
    /// `AudioInputDevice` values directly instead of calling Core Audio.
    private let devicesProvider: () -> [AudioInputDevice]

    public init() {
        self.devicesProvider = {
            AudioProcessor.getAudioDevices().map {
                AudioInputDevice(id: $0.id, name: $0.name)
            }
        }
    }

    /// Test-only initialiser accepting a fixed device list.
    internal init(devicesProvider: @escaping () -> [AudioInputDevice]) {
        self.devicesProvider = devicesProvider
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
}
