import Foundation

/// Protocol abstracting transcription for testability.
/// Real implementation uses WhisperKit; tests inject mocks.
public protocol Transcribing: Sendable {
    /// Transcribe the given audio buffer (PCM Float32, 16kHz mono).
    /// Returns the transcribed text, or throws on error.
    func transcribe(audio: [Float]) async throws -> String
}

/// Errors during transcription.
public enum TranscriptionError: Error, Sendable, Equatable {
    case modelNotReady
    case emptyAudio
    case transcriptionFailed(String)
    case noSpeechDetected
}
