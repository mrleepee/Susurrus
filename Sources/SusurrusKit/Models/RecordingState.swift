/// Represents the current recording/transcription state of the app.
public enum RecordingState: Sendable, Equatable, CaseIterable {
    /// Idle — no recording in progress.
    case idle

    // MARK: - Batch mode (Phase 7: removed after streaming is wired)

    /// Recording audio into a buffer (batch mode).
    case recording
    /// Processing the recorded buffer (batch mode).
    case processing

    // MARK: - Streaming mode

    /// Actively streaming audio and receiving interim transcriptions.
    case streaming
    /// Stream stopped, final text is being processed (LLM, clipboard, etc.).
    case finalizing
}
