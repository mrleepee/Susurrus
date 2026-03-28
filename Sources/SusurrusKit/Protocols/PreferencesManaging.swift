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

    /// Get the overridden input device identifier, if any.
    func inputDeviceID() -> String?

    /// Set the overridden input device identifier.
    func setInputDeviceID(_ id: String?)
}
