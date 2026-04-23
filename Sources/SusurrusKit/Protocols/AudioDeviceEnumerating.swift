import Foundation

/// Enumerates currently connected audio input devices and resolves a preferred
/// device name to a current device ID.
public protocol AudioDeviceEnumerating: Sendable {
    /// All currently connected input devices, in the order macOS reports them.
    func availableInputs() -> [AudioInputDevice]

    /// Resolve a preferred device name against the currently connected inputs.
    ///
    /// - Parameter preferredName: A stored device name (typically from preferences),
    ///   or `nil` if no device has been explicitly selected.
    /// - Returns: `.systemDefault` when `preferredName` is `nil`; `.specific` when the
    ///   named device is connected; `.unavailable` otherwise.
    func resolve(preferredName: String?) -> AudioDeviceResolution
}
