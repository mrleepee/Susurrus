import Foundation

/// Manages persistent storage of the user's configured hotkey.
public final class HotkeyStorage: @unchecked Sendable {

    private let defaults: UserDefaults
    private static let hotkeyKeyCodeKey = "hotkey.keyCode"
    private static let hotkeyModifiersKey = "hotkey.modifiers"
    private static let hotkeyConfiguredKey = "hotkey.configured"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a hotkey has been configured (first launch check).
    public var isConfigured: Bool {
        defaults.bool(forKey: Self.hotkeyConfiguredKey)
    }

    /// Load the saved hotkey combo, returns nil if not configured.
    public func loadCombo() -> HotkeyCombo? {
        guard isConfigured else { return nil }
        guard let keyCode = defaults.object(forKey: Self.hotkeyKeyCodeKey) as? UInt32,
              let modifiers = defaults.object(forKey: Self.hotkeyModifiersKey) as? UInt32
        else { return nil }
        return HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// Save a hotkey combo.
    public func save(combo: HotkeyCombo) {
        defaults.set(combo.keyCode, forKey: Self.hotkeyKeyCodeKey)
        defaults.set(combo.modifiers, forKey: Self.hotkeyModifiersKey)
        defaults.set(true, forKey: Self.hotkeyConfiguredKey)
    }

    /// Clear the saved hotkey (for testing/reset).
    public func clear() {
        defaults.removeObject(forKey: Self.hotkeyKeyCodeKey)
        defaults.removeObject(forKey: Self.hotkeyModifiersKey)
        defaults.set(false, forKey: Self.hotkeyConfiguredKey)
    }

    /// Create an isolated HotkeyStorage for testing purposes.
    /// Uses a unique UserDefaults suite to avoid polluting real defaults.
    public static func createForTesting() -> HotkeyStorage {
        HotkeyStorage(defaults: UserDefaults(suiteName: "com.susurrus.test.\(UUID().uuidString)")!)
    }
}
