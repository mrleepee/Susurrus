import Foundation
import Testing
@testable import SusurrusKit

// MARK: - LocalizedError conformance
//
// Notifications show error.localizedDescription. Without LocalizedError
// conformance that renders as "The operation couldn't be completed.
// (SusurrusKit.LLMError error 0.)" — these tests pin the human-readable
// descriptions so failures surfaced to the user stay meaningful.

@Suite("Error description tests")
struct ErrorDescriptionTests {

    @Test("LLMError.requestFailed passes through its reason")
    func llmRequestFailedDescription() {
        let error: Error = LLMError.requestFailed("API key not configured. Set it in Preferences > LLM.")
        #expect(error.localizedDescription == "API key not configured. Set it in Preferences > LLM.")
    }

    @Test("LLMError.invalidResponse is human-readable")
    func llmInvalidResponseDescription() {
        let error: Error = LLMError.invalidResponse
        #expect(error.localizedDescription == "The LLM returned an unexpected response.")
    }

    @Test("LLMError.emptyResult is human-readable")
    func llmEmptyResultDescription() {
        let error: Error = LLMError.emptyResult
        #expect(error.localizedDescription == "The LLM returned an empty result.")
    }

    @Test("TranscriptionError descriptions are human-readable")
    func transcriptionErrorDescriptions() {
        #expect((TranscriptionError.noSpeechDetected as Error).localizedDescription == "No speech detected.")
        #expect((TranscriptionError.modelNotReady as Error).localizedDescription
            == "The transcription model is still loading. Try again in a moment.")
        #expect((TranscriptionError.emptyAudio as Error).localizedDescription == "No audio was captured.")
        #expect((TranscriptionError.transcriptionFailed("boom") as Error).localizedDescription
            == "Transcription failed: boom")
        #expect((TranscriptionError.audioCaptureFailed as Error).localizedDescription
            == "Audio capture failed. Check the microphone connection and permissions.")
    }

    @Test("HotkeyError.registrationFailed includes the reason")
    func hotkeyErrorDescription() {
        let error: Error = HotkeyError.registrationFailed("status -9878")
        #expect(error.localizedDescription == "Hotkey registration failed: status -9878")
    }

    @Test("No error description falls back to the generic NSError text")
    func noGenericFallbackText() {
        let errors: [Error] = [
            LLMError.requestFailed("x"), LLMError.invalidResponse, LLMError.emptyResult,
            TranscriptionError.modelNotReady, TranscriptionError.emptyAudio,
            TranscriptionError.transcriptionFailed("x"), TranscriptionError.noSpeechDetected,
            TranscriptionError.audioCaptureFailed,
            HotkeyError.registrationFailed("x"),
        ]
        for error in errors {
            #expect(!error.localizedDescription.contains("The operation couldn’t be completed"))
        }
    }
}
