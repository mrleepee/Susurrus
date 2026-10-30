import FluidAudio
import Foundation
import Qwen3ASR

/// Stop-time transcription with Alibaba's Qwen3-ASR-1.7B (MLX, 8-bit, GPU)
/// via speech-swift, with the user's vocabulary as context.
///
/// Qwen3-ASR is a speech LLM: the audio encoder feeds a Qwen3 decoder whose
/// system prompt can carry free text, so names and jargon go in as a
/// comma-separated term list (the format mlx-audio uses for `hotwords`).
/// Pauses are squeezed with Silero VAD first, as for Parakeet.
///
/// On the pause-stretched read set, with the corrector: 4.5% WER, 7.2%
/// formatting errors, 65/72 terms and no term put where it wasn't said,
/// against Parakeet v2's 5.0% / 9.7% / 51/72 — at about 1.2 s per 20 s of
/// speech instead of about 0.1 s. See docs/eval-harness.md.
public actor Qwen3ASRTranscriber {

    /// Model-picker id.
    public static let modelID = "qwen3-asr-1.7b"

    /// speech-swift's MLX 8-bit conversion (~2.5 GB, cached under
    /// ~/Library/Caches/qwen3-speech on first use).
    static let huggingFaceModel = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    /// Folder name recorded with captured clips.
    public static let modelFolderName = "Qwen3-ASR-1.7B-MLX-8bit"

    /// Most vocabulary terms passed as context. The ranker orders them by
    /// relevance to the live preview, so the cut drops the least likely.
    static let maxContextTerms = 40

    public static func isQwen3(_ modelName: String) -> Bool {
        modelName == modelID
    }

    /// Whether the model weights are already on disk (no download needed).
    public static func isCached() -> Bool {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech")
        let candidates = [
            base.appendingPathComponent("models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit"),
            base.appendingPathComponent("aufklarer_Qwen3-ASR-1.7B-MLX-8bit"),
        ]
        return candidates.contains { dir in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return files.contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// The context string for a ranked term list: "Balvinder, MarkLogic, …".
    static func context(for terms: [String]) -> String? {
        let kept = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxContextTerms)
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    private var model: Qwen3ASRModel?
    private var vad: VadManager?

    public init() {}

    public var isLoaded: Bool { model != nil && vad != nil }

    /// Downloads (first use only) and loads the model and Silero VAD, then
    /// runs one warm-up pass so the first dictation doesn't pay for it.
    public func load(onDownloadProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: Self.huggingFaceModel,
            progressHandler: { fraction, _ in onDownloadProgress?(fraction) }
        )
        model = loaded
        vad = try await VadManager()
        _ = try? await transcribe(samples: ParakeetTranscriber.warmupSamples(), terms: [])
    }

    /// Squeeze pauses, then one Qwen3-ASR pass with `terms` as context.
    public func transcribe(samples: [Float], terms: [String]) async throws -> String {
        guard let model, let vad else { throw TranscriptionError.modelNotReady }
        let squeezed = try await ParakeetTranscriber.squeezePauses(samples, vad: vad)
        guard squeezed.count >= 8_000 else { return "" }
        let options = Qwen3DecodingOptions(language: "English", context: Self.context(for: terms))
        let text = try model.transcribeThrowing(audio: squeezed, sampleRate: 16_000, options: options)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
