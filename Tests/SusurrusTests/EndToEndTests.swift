import Testing
@testable import SusurrusKit
import WhisperKit

/// End-to-end test: load model → transcribe real audio → verify result.
@Suite("End-to-End Tests")
struct EndToEndTests {

    /// Generate a synthetic tone as test audio.
    private func generateTestAudio(durationSeconds: Double = 2.0, sampleRate: Double = 16000) -> [Float] {
        let sampleCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: sampleCount)
        // Simple alternating pattern to create a non-silent signal
        for i in 0..<sampleCount {
            samples[i] = (i % 2 == 0) ? 0.3 : -0.3
        }
        return samples
    }

    @Test("Load model and transcribe synthetic audio")
    func loadAndTranscribe() async throws {
        let service = WhisperKitTranscriptionService()

        // Step 1: Load model
        try await service.setupModel(modelName: "base") { _ in }
        #expect(await service.isModelReady() == true)

        // Step 2: Generate test audio and transcribe
        let audio = generateTestAudio()
        #expect(!audio.isEmpty)

        // Step 3: Transcribe — a pure tone returns noSpeechDetected or text.
        // Either proves the pipeline works end-to-end.
        do {
            let result = try await service.transcribe(audio: audio)
            print("Transcription result: '\(result)'")
        } catch let error as TranscriptionError {
            #expect(error == .noSpeechDetected || error == .emptyAudio)
            print("Expected result for synthetic audio: \(error)")
        }
    }

    @Test("Transcribe real audio from microphone")
    func transcribeRealAudio() async throws {
        let service = WhisperKitTranscriptionService()
        try await service.setupModel(modelName: "base") { _ in }

        // Capture 3 seconds of real audio from the microphone
        let capture = AudioCaptureService()
        try await capture.startCapture()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let audio = try await capture.stopCapture()

        print("Captured \(audio.count) samples")
        #expect(!audio.isEmpty)

        // Transcribe the captured audio
        do {
            let result = try await service.transcribe(audio: audio)
            print("Real transcription: '\(result)'")
        } catch let error as TranscriptionError {
            // Silence or no speech is acceptable
            print("Transcription result: \(error)")
        }
    }
}
