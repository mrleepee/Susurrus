import Observation

/// Central state management for the app.
/// Manages recording state transitions and recording mode that drive UI updates.
@Observable
@MainActor
public final class AppState {

    /// Maximum recording duration in seconds.
    public static let maxRecordingDuration: Double = 60.0

    /// Current recording/transcription state.
    public private(set) var recordingState: RecordingState = .idle

    /// Current recording mode (push-to-talk or toggle).
    public var recordingMode: RecordingMode = .pushToTalk

    /// Live interim transcript during a streaming session.
    /// Set by the streaming transcription callback and consumed by the overlay.
    public var interimText: InterimTranscript?

    /// Whether the last recording was capped by the duration limit.
    /// Must be consumed after the cap notification is shown (Behaviour 2.6).
    public private(set) var wasDurationCapped = false

    /// Whether the WhisperKit model is loaded and ready for transcription.
    public var modelReady = false

    /// Current microphone permission state.
    public var micPermission: MicPermission = .undetermined

    /// Whether a hotkey has been configured.
    public var hotkeyConfigured = false

    /// Whether the LLM hotkey (Shift+Option+Space) has been configured.
    public var llmHotkeyConfigured = false

    /// When true, the next transcription will include LLM post-processing
    /// regardless of the llmEnabled preference.
    public var forceLLM = false

    /// Download/load progress for the model (0.0 to 1.0).
    public var modelLoadProgress: Double = 0

    /// Transcription progress from 0.0 to 1.0. Updated during transcription.
    public var transcriptionProgress: Double = 0

    /// Callback invoked when recording should be auto-stopped due to duration cap.
    public var onDurationCap: (() -> Void)?

    public init() {}

    // MARK: - Batch mode (Phase 7: removed after streaming is wired)

    /// Transition to recording state from idle (batch mode).
    /// Requires model to be ready.
    public func startRecording() {
        guard recordingState == .idle, modelReady else { return }
        wasDurationCapped = false
        recordingState = .recording
    }

    /// Stop recording and begin processing (batch mode).
    public func stopRecording() {
        guard recordingState == .recording else { return }
        recordingState = .processing
    }

    /// Transition back to idle after processing completes (batch mode).
    public func finishProcessing() {
        guard recordingState == .processing else { return }
        transcriptionProgress = 0
        recordingState = .idle
    }

    // MARK: - Streaming mode

    /// Begin a streaming session. Requires model to be ready.
    /// Sets interimText to nil/empty and resets wasDurationCapped.
    public func startStreaming() {
        guard recordingState == .idle, modelReady else { return }
        wasDurationCapped = false
        interimText = nil
        recordingState = .streaming
    }

    /// Stop the streaming session and begin finalization.
    public func stopStreaming() {
        guard recordingState == .streaming else { return }
        recordingState = .finalizing
    }

    /// Transition back to idle after finalization completes.
    /// Clears interimText.
    public func finishStreaming() {
        guard recordingState == .finalizing else { return }
        interimText = nil
        recordingState = .idle
    }

    // MARK: - Duration cap

    /// Enforce the 60-second recording duration cap.
    /// Call this when the recording timer fires.
    /// Returns true if recording was capped.
    @discardableResult
    public func enforceDurationCap() -> Bool {
        guard recordingState == .recording || recordingState == .streaming else { return false }
        wasDurationCapped = true
        stopStreaming()
        onDurationCap?()
        return true
    }

    /// Consume the wasDurationCapped flag after the cap notification has been shown.
    /// Called by the app after the notification fires (Behaviour 2.6).
    public func consumeDurationCapped() {
        wasDurationCapped = false
    }

    // MARK: - Cancel

    /// Cancel and return to idle from any state.
    public func cancel() {
        recordingState = .idle
        interimText = nil
    }

    // MARK: - Hotkey handling

    /// Handle hotkey press based on current recording mode.
    /// Returns true if recording started, false if stopped or cancelled.
    @discardableResult
    public func handleHotkeyDown() -> Bool {
        switch recordingMode {
        case .pushToTalk:
            startStreaming()
            return recordingState == .streaming
        case .toggle:
            if recordingState == .idle {
                startStreaming()
                return true
            } else if recordingState == .streaming {
                stopStreaming()
                return false
            }
            return false
        }
    }

    /// Handle hotkey release (used for push-to-talk mode).
    public func handleHotkeyUp() {
        guard recordingMode == .pushToTalk else { return }
        stopStreaming()
    }
}
