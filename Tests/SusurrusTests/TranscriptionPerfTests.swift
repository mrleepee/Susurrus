import CoreML
import Testing
@testable import SusurrusKit
import WhisperKit

/// Performance benchmarks for WhisperKit transcription.
///
/// Run with: `make perf`
///
/// Strategy: Load model once per compute-unit config, then vary decoding options
/// without reloading. This avoids the dominant cost of model loading and produces
/// clean transcription-timing numbers.
@Suite("Transcription Performance", .tags(.performance))
struct TranscriptionPerfTests {

    /// A single benchmark measurement.
    struct BenchResult: CustomStringConvertible {
        let compute: String
        let chunking: String
        let workers: Int
        let model: String
        let durationMs: Double
        let audioDurationSec: Double
        let realtimeFactor: Double

        var description: String {
            let ms = String(format: "%7.1f", durationMs)
            let rt = String(format: "%.2f", realtimeFactor)
            return "\(model) | \(compute) | \(chunking) | w=\(workers) => \(ms)ms (RTx=\(rt))"
        }
    }

    private func computeName(_ c: MLComputeUnits) -> String {
        switch c {
        case .cpuOnly: "CPU"
        case .cpuAndGPU: "GPU"
        case .cpuAndNeuralEngine: "ANE"
        case .all: "All"
        default: "?"
        }
    }

    private func measureMs(_ block: @escaping () async throws -> Void) async -> Double {
        let start = Date()
        _ = try? await block()
        return Date().timeIntervalSince(start) * 1000
    }

    /// Benchmark a single model+compute combo across all decoding variations.
    /// Model is loaded once, then reused for every decoding config.
    private func benchmarkModel(
        model: String,
        compute: MLComputeUnits,
        audio: [Float]
    ) async -> [BenchResult] {
        let computeStr = computeName(compute)
        let audioDur = Double(audio.count) / 16000.0

        print("\n[PERF] --- Loading \(model) with \(computeStr) ---")

        let service = WhisperKitTranscriptionService()
        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: compute,
            textDecoderCompute: compute
        )

        do {
            let loadMs = await measureMs {
                try await service.setupModel(
                    modelName: model,
                    computeOptions: computeOptions
                ) { _ in }
            }
            print("[PERF] Model load: \(String(format: "%.0f", loadMs))ms")
        } catch {
            print("[PERF] Model load FAILED: \(error)")
            return []
        }

        // Warmup run
        let warmupOptions = DecodingOptions(
            task: .transcribe, language: nil,
            concurrentWorkerCount: 4, chunkingStrategy: .vad
        )
        _ = try? await service.transcribe(audio: audio, decodeOptions: warmupOptions)

        let chunkings: [ChunkingStrategy] = [.none, .vad]
        let workerCounts = [1, 2, 4, 8]
        var results: [BenchResult] = []

        for chunking in chunkings {
            for workers in workerCounts {
                let options = DecodingOptions(
                    task: .transcribe, language: nil,
                    concurrentWorkerCount: workers,
                    chunkingStrategy: chunking
                )

                // Run 3 times, take median
                var timings: [Double] = []
                for _ in 0..<3 {
                    let ms = await measureMs {
                        _ = try? await service.transcribe(audio: audio, decodeOptions: options)
                    }
                    timings.append(ms)
                }
                timings.sort()
                let median = timings[1] // middle of 3

                let rtx = audioDur / (median / 1000.0)
                let result = BenchResult(
                    compute: computeStr,
                    chunking: chunking.rawValue,
                    workers: workers,
                    model: model,
                    durationMs: median,
                    audioDurationSec: audioDur,
                    realtimeFactor: rtx
                )
                results.append(result)
                print("[PERF] \(result)")
            }
        }

        await service.unloadModel()
        return results
    }

    private func printSummary(_ title: String, results: [BenchResult]) {
        let sorted = results.sorted { $0.durationMs < $1.durationMs }
        print("\n[PERF] ===== \(title) =====")
        print("[PERF] Rank | Config | Median(ms) | RT Factor")
        print("[PERF] -----|--------|------------|----------")
        for (i, r) in sorted.enumerated() {
            let ms = String(format: "%7.1f", r.durationMs)
            let rt = String(format: "%.2f", r.realtimeFactor)
            print("[PERF]   \(i + 1)  | \(r.model) | \(r.compute) | \(r.chunking) | w=\(r.workers) | \(ms)ms | \(rt)x")
        }
        if let best = sorted.first {
            print("[PERF] BEST: \(best.model) | \(best.compute) | \(best.chunking) | w=\(best.workers) => \(String(format: "%.1f", best.durationMs))ms")
        }
    }

    // MARK: - Tests (run sequentially with .serialized)

    @Test("Benchmark: base model across compute units and decoding options")
    func benchmarkBaseModel() async throws {
        let audio = try await captureAudio(durationSeconds: 5.0)
        print("[PERF] Audio: \(audio.count) samples (\(String(format: "%.1f", Double(audio.count) / 16000.0))s)")

        let computes: [MLComputeUnits] = [.cpuAndNeuralEngine, .cpuAndGPU, .all]
        var allResults: [BenchResult] = []

        for compute in computes {
            let results = await benchmarkModel(model: "base", compute: compute, audio: audio)
            allResults.append(contentsOf: results)
        }

        printSummary("BASE MODEL SUMMARY", results: allResults)
        #expect(!allResults.isEmpty)
    }

    @Test("Benchmark: small model with best compute from base")
    func benchmarkSmallModel() async throws {
        let audio = try await captureAudio(durationSeconds: 5.0)
        print("[PERF] Audio: \(audio.count) samples (\(String(format: "%.1f", Double(audio.count) / 16000.0))s)")

        // Test small with all compute options to find best
        let computes: [MLComputeUnits] = [.cpuAndNeuralEngine, .cpuAndGPU, .all]
        var allResults: [BenchResult] = []

        for compute in computes {
            let results = await benchmarkModel(model: "small", compute: compute, audio: audio)
            allResults.append(contentsOf: results)
        }

        printSummary("SMALL MODEL SUMMARY", results: allResults)
        #expect(!allResults.isEmpty)
    }

    // MARK: - Audio capture

    private func captureAudio(durationSeconds: Double = 5.0) async throws -> [Float] {
        let capture = AudioCaptureService()
        try await capture.startCapture()
        try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
        let audio = try await capture.stopCapture()
        return audio
    }
}

extension Tag {
    @Tag static var performance: Tag
}
