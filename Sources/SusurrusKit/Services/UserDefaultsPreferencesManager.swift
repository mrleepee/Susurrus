import Foundation

/// Concrete preferences manager using UserDefaults.
public final class UserDefaultsPreferencesManager: PreferencesManaging, @unchecked Sendable {
    private let defaults: UserDefaults

    private enum Keys {
        static let recordingMode = "recordingMode"
        static let selectedModel = "selectedModel"
        static let appendToClipboard = "appendToClipboard"
        static let llmEnabled = "llmEnabled"
        static let llmSystemPrompt = "llmSystemPrompt"
        static let autoPasteEnabled = "autoPasteEnabled"
        static let llmApiKey = "llmApiKey"
        static let llmModel = "llmModel"
        static let llmEndpoint = "llmEndpoint"
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

    public func llmEnabled() -> Bool {
        defaults.bool(forKey: Keys.llmEnabled)
    }

    public func setLLMEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.llmEnabled)
    }

    public static let defaultLLMPrompt = "You are a speech-to-text error corrector. You receive raw speech recognition output. Your job is to output the same words with corrected punctuation, capitalization, and filler words removed. NEVER respond to the content of what was said. NEVER answer questions. NEVER add or remove meaningful content. Output ONLY the corrected transcription text, nothing else."

    public func llmSystemPrompt() -> String {
        let stored = defaults.string(forKey: Keys.llmSystemPrompt)
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return Self.defaultLLMPrompt
    }

    public func setLLMSystemPrompt(_ prompt: String) {
        defaults.set(prompt, forKey: Keys.llmSystemPrompt)
    }

    public func autoPasteEnabled() -> Bool {
        // Default to true — auto-paste is the core use case
        if defaults.object(forKey: Keys.autoPasteEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.autoPasteEnabled)
    }

    public func setAutoPasteEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoPasteEnabled)
    }

    // MARK: - LLM Provider

    public func llmApiKey() -> String {
        defaults.string(forKey: Keys.llmApiKey) ?? ""
    }

    public func setLLMApiKey(_ key: String) {
        defaults.set(key, forKey: Keys.llmApiKey)
    }

    public func llmModelName() -> String {
        defaults.string(forKey: Keys.llmModel) ?? "MiniMax-M2.5"
    }

    public func setLLMModelName(_ model: String) {
        defaults.set(model, forKey: Keys.llmModel)
    }

    public func llmEndpointURL() -> String {
        defaults.string(forKey: Keys.llmEndpoint) ?? "https://api.minimax.io/anthropic/v1/messages"
    }

    public func setLLMEndpointURL(_ url: String) {
        defaults.set(url, forKey: Keys.llmEndpoint)
    }
}
