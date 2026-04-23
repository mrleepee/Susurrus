/// Protocol for managing user preferences.
public protocol PreferencesManaging: Sendable {
    /// Get the current recording mode preference.
    func recordingMode() -> RecordingMode

    /// Set the recording mode preference.
    func setRecordingMode(_ mode: RecordingMode)

    /// Get the selected model name.
    func selectedModel() -> String

    /// Set the selected model name.
    func setSelectedModel(_ model: String)

    /// Whether append-to-clipboard mode is enabled.
    func appendToClipboard() -> Bool

    /// Set append-to-clipboard mode.
    func setAppendToClipboard(_ enabled: Bool)

    /// Whether LLM post-processing is enabled.
    func llmEnabled() -> Bool

    /// Set LLM post-processing enabled.
    func setLLMEnabled(_ enabled: Bool)

    /// Get the LLM system prompt.
    func llmSystemPrompt() -> String

    /// Set the LLM system prompt.
    func setLLMSystemPrompt(_ prompt: String)

    /// Whether auto-paste at cursor is enabled.
    func autoPasteEnabled() -> Bool

    /// Set auto-paste at cursor enabled.
    func setAutoPasteEnabled(_ enabled: Bool)

    /// Name of the preferred input audio device, or `nil` to use the system default.
    /// Stored as name (not ID) because Core Audio `AudioDeviceID`s are not stable
    /// across device reconnections.
    func selectedInputDeviceName() -> String?

    /// Set the preferred input audio device name. Pass `nil` to revert to system default.
    func setSelectedInputDeviceName(_ name: String?)
}
