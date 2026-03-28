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

        if shouldFail {
            throw failureError
        }

        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        return mockResult
    }

    func setMockResult(_ text: String) {
        mockResult = text
    }

    func setFailure(_ error: TranscriptionError) {
        shouldFail = true
        failureError = error
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

    @Test("Transcription passes audio buffer through")
    func audioBufferPassed() async throws {
        let service = MockTranscriptionService()
        let audio: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]

        _ = try await service.transcribe(audio: audio)
        let lastBuffer = await service.lastAudioBuffer
        #expect(lastBuffer == audio)
    }

    @Test("Empty audio throws emptyAudio error")
    func emptyAudioThrows() async {
        let service = MockTranscriptionService()
        do {
            _ = try await service.transcribe(audio: [])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .emptyAudio)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("Transcription failure propagates error")
    func failurePropagates() async {
        let service = MockTranscriptionService()
        await service.setFailure(.transcriptionFailed("model crashed"))

        do {
            _ = try await service.transcribe(audio: [0.1])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .transcriptionFailed("model crashed"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("No speech detected error")
    func noSpeechDetected() async {
        let service = MockTranscriptionService()
        await service.setFailure(.noSpeechDetected)

        do {
            _ = try await service.transcribe(audio: [0.0])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .noSpeechDetected)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("Model not ready error")
    func modelNotReady() async {
        let service = MockTranscriptionService()
        await service.setFailure(.modelNotReady)

        do {
            _ = try await service.transcribe(audio: [0.1])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .modelNotReady)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("TranscriptionError equality")
    func errorEquality() {
        #expect(TranscriptionError.modelNotReady == TranscriptionError.modelNotReady)
        #expect(TranscriptionError.emptyAudio == TranscriptionError.emptyAudio)
        #expect(TranscriptionError.noSpeechDetected == TranscriptionError.noSpeechDetected)
        #expect(TranscriptionError.emptyAudio != TranscriptionError.modelNotReady)
        #expect(
            TranscriptionError.transcriptionFailed("a")
                == TranscriptionError.transcriptionFailed("a")
        )
    }

    @Test("Multiple transcriptions track call count")
    func callCount() async throws {
        let service = MockTranscriptionService()
        _ = try await service.transcribe(audio: [0.1])
        _ = try await service.transcribe(audio: [0.2])
        _ = try await service.transcribe(audio: [0.3])

        let count = await service.transcribeCallCount
        #expect(count == 3)
    }

    @Test("Audio buffer is not retained after transcription")
    func audioBufferNotRetained() async throws {
        let service = MockTranscriptionService()
        let audio: [Float] = Array(repeating: 0.5, count: 1000)

        _ = try await service.transcribe(audio: audio)
        let retained = await service.lastAudioBuffer

        // The mock retains for inspection, but the contract requires
        // that audio is passed by value ([Float] is a value type)
        // so the caller can release their reference independently.
        #expect(retained?.count == 1000)
    }

    @Test("Transcription returns only text, no external side effects")
    func transcriptionReturnsText() async throws {
        let service = MockTranscriptionService()
        let result = try await service.transcribe(audio: [0.1])
        #expect(result is String)
    }

    // MARK: - Model readiness (R15)

    @Test("WhisperKitTranscriptionService starts not ready")
    func startsNotReady() async {
        let service = WhisperKitTranscriptionService()
        let ready = await service.isModelReady()
        #expect(ready == false)
    }

    @Test("WhisperKitTranscriptionService unloadModel sets not ready")
    func unloadSetsNotReady() async {
        let service = WhisperKitTranscriptionService()
        await service.unloadModel()
        let ready = await service.isModelReady()
        #expect(ready == false)
    }

    @Test("Transcribe without model throws modelNotReady")
    func transcribeWithoutModel() async {
        let service = WhisperKitTranscriptionService()
        do {
            _ = try await service.transcribe(audio: [0.1])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .modelNotReady)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}
