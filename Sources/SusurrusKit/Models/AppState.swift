import Observation

/// Central state management for the app.
/// Manages recording state transitions and recording mode that drive UI updates.
@Observable
@MainActor
public final class AppState {

    /// Current recording/transcription state.
    public private(set) var recordingState: RecordingState = .idle

    /// Current recording mode (push-to-talk or toggle).
    public var recordingMode: RecordingMode = .pushToTalk

    public init() {}

    /// Transition to recording state from idle.
    public func startRecording() {
        guard recordingState == .idle else { return }
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
        recordingState = .idle
    }

    /// Cancel and return to idle from any state.
    public func cancel() {
        recordingState = .idle
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
    @discardableResult
    public func handleHotkeyUp() {
        guard recordingMode == .pushToTalk else { return }
        stopRecording()
    }
}
