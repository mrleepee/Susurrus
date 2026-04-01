import Foundation

// MARK: - Protocols

/// Protocol abstracting batch transcription for testability.
/// Real implementation uses WhisperKit; tests inject mocks.
public protocol Transcribing: Sendable {
    /// Transcribe the given audio buffer (PCM Float32, 16kHz mono).
    /// Returns the transcribed text, or throws on error.
    func transcribe(audio: [Float]) async throws -> String
}

/// Protocol abstracting streaming transcription for testability.
/// Real implementation uses WhisperKit's AudioStreamTranscriber.
public protocol StreamTranscribing: Sendable {
    /// Begin streaming transcription. Callback fires with interim transcripts.
    func startStreamTranscription(callback: @escaping (InterimTranscript) -> Void) async throws

    /// Stop streaming and return the final transcript.
    func stopStreamTranscription() async throws -> String
}

// MARK: - Errors

/// Errors during transcription.
public enum TranscriptionError: Error, Sendable, Equatable {
    case modelNotReady
    case emptyAudio
    case transcriptionFailed(String)
    case noSpeechDetected
    case audioCaptureFailed
}
