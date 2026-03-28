import Foundation

/// Represents a keyboard shortcut (keycode + modifier flags).
public struct HotkeyCombo: Sendable, Equatable, Codable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default hotkey: Cmd+Shift+A
    public static let `default` = HotkeyCombo(keyCode: 0, modifiers: 0)
}

/// Protocol for managing global hotkeys.
public protocol HotkeyManaging: Sendable {
    /// Register a global hotkey with the given combo.
    /// Calls onKeyDown when the key is pressed, onKeyUp on release.
    func register(
        combo: HotkeyCombo,
        onKeyDown: @Sendable @escaping () -> Void,
        onKeyUp: @Sendable @escaping () -> Void
    ) async throws

    /// Unregister the current hotkey.
    func unregister() async

    /// Whether a hotkey is currently registered.
    func isRegistered() async -> Bool
}

/// Convenience overload for key-down only (e.g., toggle mode).
extension HotkeyManaging {
    public func register(
        combo: HotkeyCombo,
        onKeyDown: @Sendable @escaping () -> Void
    ) async throws {
        try await register(combo: combo, onKeyDown: onKeyDown, onKeyUp: {})
    }
}
