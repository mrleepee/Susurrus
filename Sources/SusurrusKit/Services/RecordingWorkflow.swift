import Foundation

/// Orchestrates the full recording → transcription → clipboard pipeline.
/// Wired to AppState for UI updates and delegates to injected services.
public actor RecordingWorkflow {

    private let audioCapture: AudioCapturing
    private let transcriptionService: Transcribing
    private let clipboard: ClipboardManaging
    private let notificationService: Notifying
    private let preferences: PreferencesManaging
    private let vocabularyManager: VocabularyManaging

    public init(
        audioCapture: AudioCapturing,
        transcriptionService: Transcribing,
        clipboard: ClipboardManaging,
        notificationService: Notifying,
        preferences: PreferencesManaging,
        vocabularyManager: VocabularyManaging
    ) {
        self.audioCapture = audioCapture
        self.transcriptionService = transcriptionService
        self.clipboard = clipboard
        self.notificationService = notificationService
        self.preferences = preferences
        self.vocabularyManager = vocabularyManager
    }

    /// Start audio capture. Call when recording begins.
    public func startRecording() async throws {
        try await audioCapture.startCapture()
    }

    /// Stop capture, transcribe, and deliver result to clipboard.
    /// Updates appState through the provided callbacks.
    public func stopRecordingAndTranscribe(
        appendMode: Bool,
        onTranscriptionProgress: @Sendable (Double) -> Void
    ) async throws -> String? {
        // Stop audio capture and get buffer
        let audioBuffer = try await audioCapture.stopCapture()

        guard !audioBuffer.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        // Transcribe
        let text = try await transcriptionService.transcribe(audio: audioBuffer)

        guard !text.isEmpty else {
            notificationService.showNotification(
                title: "Susurrus",
                body: "No speech detected"
            )
            return nil
        }

        // Write to clipboard
        if appendMode {
            clipboard.appendText(text)
        } else {
            clipboard.writeText(text)
        }

        // Notify
        notificationService.showNotification(
            title: "Susurrus",
            body: "Copied to clipboard"
        )

        return text
    }
}
