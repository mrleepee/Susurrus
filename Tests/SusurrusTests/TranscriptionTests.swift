import Testing
@testable import SusurrusKit

/// Mock transcription service for testing without WhisperKit model.
actor MockTranscriptionService: Transcribing {
    var shouldFail = false
    var failureError: TranscriptionError = .transcriptionFailed("mock error")
    var mockResult = "Hello, world!"
    var transcribeCallCount = 0
    var lastAudioBuffer: [Float]?

    func transcribe(audio: [Float]) async throws -> String {
        transcribeCallCount += 1
        lastAudioBuffer = audio
        if shouldFail { throw failureError }
        guard !audio.isEmpty else { throw TranscriptionError.emptyAudio }
        return mockResult
    }

    func setMockResult(_ text: String) { mockResult = text }
    func setFailure(_ error: TranscriptionError) { shouldFail = true; failureError = error }
}

/// Mock streaming transcription service for testing.
actor MockStreamTranscriptionService: StreamTranscribing {
    var shouldFail = false
    var shouldThrowNoSpeech = false
    var mockTranscript = InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)
    var mockFinalText = "Hello world"
    var startCallCount = 0
    var stopCallCount = 0
    var lastCallback: ((InterimTranscript) -> Void)?

    func startStreamTranscription(callback: @escaping (InterimTranscript) -> Void) async throws {
        startCallCount += 1
        lastCallback = callback
        // Emit an interim transcript immediately
        callback(mockTranscript)
    }

    func stopStreamTranscription() async throws -> String {
        stopCallCount += 1
        if shouldThrowNoSpeech { throw TranscriptionError.noSpeechDetected }
        if shouldFail { throw TranscriptionError.audioCaptureFailed }
        // Emit final transcript
        lastCallback?(InterimTranscript(confirmed: mockFinalText, unconfirmed: "", isFinal: true))
        return mockFinalText
    }

    func reset() {
        shouldFail = false
        shouldThrowNoSpeech = false
        startCallCount = 0
        stopCallCount = 0
        lastCallback = nil
    }
}

@Suite("Transcription Tests")
struct TranscriptionTests {

    @Test("Successful transcription returns text")
    func successfulTranscription() async throws {
        let service = MockTranscriptionService()
        await service.setMockResult("Hello, world!")
        let result = try await service.transcribe(audio: [0.1, 0.2, 0.3])
        #expect(result == "Hello, world!")
    }

    @Test("Streaming: startStreamTranscription emits interim callback")
    func streamingStartEmitsCallback() async throws {
        let service = MockStreamTranscriptionService()
        var receivedTranscript: InterimTranscript?
        try await service.startStreamTranscription { transcript in
            receivedTranscript = transcript
        }
        #expect(receivedTranscript?.confirmed == "Hello ")
        #expect(receivedTranscript?.unconfirmed == "world")
        #expect(receivedTranscript?.isFinal == false)
    }

    @Test("Streaming: stopStreamTranscription returns final text")
    func streamingStopReturnsFinal() async throws {
        let service = MockStreamTranscriptionService()
        await service.setMockResult("Final transcript")
        try await service.startStreamTranscription { _ in }
        let text = try await service.stopStreamTranscription()
        #expect(text == "Final transcript")
    }

    @Test("Streaming: noSpeechDetected throws when text is empty")
    func streamingNoSpeech() async throws {
        let service = MockStreamTranscriptionService()
        await service.setMockResult("")
        try await service.startStreamTranscription { _ in }
        do {
            _ = try await service.stopStreamTranscription()
            #expect(false, "Should have thrown")
        } catch TranscriptionError.noSpeechDetected {
            // expected
        }
    }
}
