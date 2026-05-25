import Foundation

/// A selectable audio input device.
///
/// `id` is a Core Audio `AudioDeviceID` (UInt32) that is NOT stable across device
/// reconnections — the same USB mic may receive a different ID after being unplugged
/// and replugged. Use `name` as the stable identifier for persistence (see DeviceService
/// resolution logic).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

/// The result of resolving a preferred device name against the currently connected
/// set of input devices.
public enum AudioDeviceResolution: Sendable, Equatable {
    /// A specific device was requested and is currently connected.
    case specific(id: UInt32, name: String)

    /// No specific device was requested (or no preference stored) — use system default.
    case systemDefault

    /// A specific device was requested but is not currently connected.
    /// Callers should fall back to system default and surface this to the user.
    case unavailable(requestedName: String)
}
