import CoreML
import Foundation
import Testing
@testable import SusurrusKit
import WhisperKit

/// Decomposes the stop-time final decode into its cost components, using a
/// deterministic fixture instead of live audio:
///
///   1. Baseline decode (no prompt tokens, no word timestamps)
///   2. Prompt-token prefill tax (~half and full 48-token budget)
///   3. wordTimestamps alignment tax (the gate for confidence highlighting)
///
/// Every dictation pays the stop-time decode, so regressions here hit the
/// felt latency directly. Production logs (2026-07) show all decodes carry
/// the full 48-token budget — this bench says what that actually costs.
@Suite("Stop Latency Decomposition", .tags(.performance))
struct StopLatencyPerfTests {

    private static let fixture = "test_clip_10s.wav"

    /// Realistic vocab strings sized to roughly half and full budget.
    private static let smallPrompt = "MarkLogic, SPARQL, Susurrus, Datavid, CoRB, QAS"
    private static let largePrompt = """
        MarkLogic, SPARQL, Susurrus, Datavid, CoRB, QAS, Balvinder, Jayendra, \
        Abhishek, Kashish, Pankaj, Brinda, SciFinder, Anwar, Schengen, BioFinder
        """

    private func loadFixture() throws -> [Float] {
        let path = FileManager.default.currentDirectoryPath + "/" + Self.fixture
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.transcriptionFailed("fixture missing: \(path)")
        }
        let buffer = try AudioProcessor.loadAudio(fromPath: path)
        return AudioProcessor.convertBufferToArray(buffer: buffer)
    }

    private func medianMs(runs: Int = 3, _ block: () async throws -> Void) async -> Double {
        var timings: [Double] = []
        for _ in 0..<runs {
            let start = Date()
            _ = try? await block()
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        timings.sort()
        return timings[timings.count / 2]
    }

    @Test("Prompt-token and wordTimestamps cost on the final decode")
    func stopLatencyTaxes() async throws {
        let audio = try loadFixture()
        let service = WhisperKitTranscriptionService()
        try await service.setupModel(
            modelName: "small",
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        ) { _ in }

        let base = DecodingOptions(
            task: .transcribe, language: "en",
            concurrentWorkerCount: 4, chunkingStrategy: .vad
        )
        var withTimestamps = base
        withTimestamps.wordTimestamps = true

        // Warmup (compile ANE plans for both option shapes).
        _ = try? await service.transcribe(audio: audio, decodeOptions: base)
        _ = try? await service.transcribe(audio: audio, decodeOptions: withTimestamps)

        func bench(_ label: String, prompt: String, options: DecodingOptions) async -> Double {
            await service.setVocabularyPrompt(prompt)
            let tokens = await service.vocabularyPromptTokenCount() ?? 0
            let ms = await medianMs {
                _ = try await service.transcribe(audio: audio, decodeOptions: options)
            }
            print("[PERF] stop-latency | \(label) | promptTokens=\(tokens) | \(String(format: "%7.1f", ms))ms")
            return ms
        }

        let baseline = await bench("baseline           ", prompt: "", options: base)
        let half = await bench("half prompt        ", prompt: Self.smallPrompt, options: base)
        let full = await bench("full prompt        ", prompt: Self.largePrompt, options: base)
        let stamps = await bench("wordTimestamps     ", prompt: "", options: withTimestamps)
        let everything = await bench("prompt + timestamps", prompt: Self.largePrompt, options: withTimestamps)

        print("[PERF] ===== STOP LATENCY TAXES (10s clip, small/ANE) =====")
        print("[PERF] prompt tax (half): \(String(format: "%+.0f", half - baseline))ms")
        print("[PERF] prompt tax (full): \(String(format: "%+.0f", full - baseline))ms")
        print("[PERF] wordTimestamps tax: \(String(format: "%+.0f", stamps - baseline))ms")
        print("[PERF] everything-on total: \(String(format: "%.0f", everything))ms vs baseline \(String(format: "%.0f", baseline))ms")

        await service.unloadModel()
        #expect(baseline > 0)
    }
}
