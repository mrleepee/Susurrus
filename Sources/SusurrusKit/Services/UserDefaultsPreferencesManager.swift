import Foundation

/// Concrete preferences manager using UserDefaults.
public final class UserDefaultsPreferencesManager: PreferencesManaging, @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Keys {
        static let recordingMode = "recordingMode"
        static let selectedModel = "selectedModel"
        static let appendToClipboard = "appendToClipboard"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Factory for testing with an isolated UserDefaults suite.
    public static func createForTesting() -> UserDefaultsPreferencesManager {
        UserDefaultsPreferencesManager(defaults: UserDefaults(suiteName: "com.susurrus.prefs.test.\(UUID().uuidString)")!)
    }

    public func recordingMode() -> RecordingMode {
        guard let raw = defaults.string(forKey: Keys.recordingMode) else {
            return .pushToTalk
        }
        return RecordingMode(rawValue: raw) ?? .pushToTalk
    }

    public func setRecordingMode(_ mode: RecordingMode) {
        defaults.set(mode.rawValue, forKey: Keys.recordingMode)
    }

    public func selectedModel() -> String {
        defaults.string(forKey: Keys.selectedModel) ?? "base"
    }

    public func setSelectedModel(_ model: String) {
        defaults.set(model, forKey: Keys.selectedModel)
    }

    public func appendToClipboard() -> Bool {
        defaults.bool(forKey: Keys.appendToClipboard)
    }

    public func setAppendToClipboard(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.appendToClipboard)
    }

    public func inputDeviceID() -> String? {
        defaults.string(forKey: "inputDeviceID")
    }

    public func setInputDeviceID(_ id: String?) {
        defaults.set(id, forKey: "inputDeviceID")
    }
}
