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

    /// Whether the last recording was capped by the duration limit.
    public private(set) var wasDurationCapped = false

    /// Whether the WhisperKit model is loaded and ready for transcription.
    public var modelReady = false

    /// Download/load progress for the model (0.0 to 1.0).
    public var modelLoadProgress: Double = 0

    /// Transcription progress from 0.0 to 1.0. Updated during transcription.
    public var transcriptionProgress: Double = 0

    /// Callback invoked when recording should be auto-stopped due to duration cap.
    public var onDurationCap: (() -> Void)?

    public init() {}

    /// Transition to recording state from idle.
    /// Requires model to be ready.
    public func startRecording() {
        guard recordingState == .idle, modelReady else { return }
        wasDurationCapped = false
        recordingState = .recording
    }

    /// Stop recording and begin processing.
    public func stopRecording() {
        guard recordingState == .recording else { return }
        recordingState = .processing
    }

    /// Transition back to idle after processing completes.
    public func finishProcessing() {
        guard recordingState == .processing else { return }
        transcriptionProgress = 0
        recordingState = .idle
    }

    /// Cancel and return to idle from any state.
    public func cancel() {
        recordingState = .idle
    }

    /// Enforce the 60-second recording duration cap.
    /// Call this when the recording timer fires.
    /// Returns true if recording was capped.
    @discardableResult
    public func enforceDurationCap() -> Bool {
        guard recordingState == .recording else { return false }
        wasDurationCapped = true
        stopRecording()
        onDurationCap?()
        return true
    }

    /// Handle hotkey press based on current recording mode.
    /// Returns true if recording started, false if stopped.
    @discardableResult
    public func handleHotkeyDown() -> Bool {
        switch recordingMode {
        case .pushToTalk:
            startRecording()
            return recordingState == .recording
        case .toggle:
            if recordingState == .idle {
                startRecording()
                return true
            } else if recordingState == .recording {
                stopRecording()
                return false
            }
            return false
        }
    }

    /// Handle hotkey release (used for push-to-talk mode).
    public func handleHotkeyUp() {
        guard recordingMode == .pushToTalk else { return }
        stopRecording()
    }
}
