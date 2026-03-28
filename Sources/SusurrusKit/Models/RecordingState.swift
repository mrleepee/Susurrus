/// Represents the current recording/transcription state of the app.
public enum RecordingState: Sendable, Equatable, CaseIterable {
    case idle
    case recording
    case processing
}
