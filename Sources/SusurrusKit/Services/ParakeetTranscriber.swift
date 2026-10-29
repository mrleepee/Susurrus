import FluidAudio
import Foundation

/// Stop-time transcription with NVIDIA Parakeet on the Neural Engine, via
/// FluidAudio: TDT 0.6B v2 (English) or Unified 0.6B (English, RNN-T, full
/// attention over 15 s windows).
///
/// Long pauses are cut down first with Silero VAD: given several seconds of
/// room tone, every model tried invents words (Whisper "thank you" / "you",
/// Parakeet repetition loops like "put it in put it in"). On the read-aloud
/// set with stretched pauses, VAD + Parakeet + the corrector matched
/// large-v3's word accuracy with fewer formatting errors, at about 0.2 s per
/// minute of audio instead of about 15 s. See docs/eval-harness.md.
public actor ParakeetTranscriber {

    /// The Parakeet models on offer. The raw value is the model-picker id.
    /// On the pause-stretched read set (with the corrector), Unified made
    /// fewer word errors than v2 (4.6% vs 5.0%) and far fewer stray sentence
    /// breaks (3 vs 15), but used fewer commas and full stops overall
    /// (formatting errors 10.8% vs 9.7%).
    public enum Variant: String, CaseIterable, Sendable {
        case v2 = "parakeet-v2"
        case unified = "parakeet-unified"

        /// Folder name recorded with captured clips.
        public var modelFolderName: String {
            switch self {
            case .v2: return "parakeet-tdt-0.6b-v2"
            case .unified: return "parakeet-unified-en-0.6b"
            }
        }
    }

    /// Model-picker id of the default variant. The live preview still runs
    /// on Whisper (`previewWhisperModel`).
    public static let modelID = Variant.v2.rawValue

    /// Whisper model that drives capture and the live preview overlay while
    /// Parakeet does the final transcription.
    public static let previewWhisperModel = "small"

    public static func isParakeet(_ modelName: String) -> Bool {
        Variant(rawValue: modelName) != nil
    }

    /// Whether a variant's models are already on disk (no download needed).
    public static func isCached(_ variant: Variant) -> Bool {
        switch variant {
        case .v2:
            return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        case .unified:
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FluidAudio/Models/\(variant.modelFolderName)")
            let files = [ModelNames.ParakeetUnified.offlineEncoderInt8File, ModelNames.ParakeetUnified.decoderFile,
                         ModelNames.ParakeetUnified.jointDecisionFile, ModelNames.ParakeetUnified.vocab]
            return files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    /// Room tone kept at each side of a squeezed pause, in samples (0.3 s).
    static let keptSilence = 4_800

    private static let sampleRate = 16_000

    public let variant: Variant
    private var tdt: AsrManager?
    private var unified: UnifiedAsrManager?
    private var vad: VadManager?

    public init(variant: Variant = .v2) {
        self.variant = variant
    }

    /// Downloads (first use only: v2 ~480 MB, Unified ~600 MB) and loads the
    /// model and Silero VAD, then runs one warm-up pass so the Neural Engine
    /// compile cost lands here.
    public func load(onDownloadProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let progress: ProgressHandler = { onDownloadProgress?($0.fractionCompleted) }
        switch variant {
        case .v2:
            let models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: progress)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            tdt = manager
        case .unified:
            let manager = UnifiedAsrManager()
            try await manager.loadModels(progressHandler: progress)
            unified = manager
        }
        vad = try await VadManager()
        _ = try? await transcribe(samples: Self.warmupSamples())
    }

    public var isLoaded: Bool { (tdt != nil || unified != nil) && vad != nil }

    /// Transcribes a 16 kHz mono buffer: squeeze pauses, then one Parakeet pass.
    public func transcribe(samples: [Float]) async throws -> String {
        guard let vad, isLoaded else { throw TranscriptionError.modelNotReady }
        let squeezed = try await Self.squeezePauses(samples, vad: vad)
        guard squeezed.count >= Self.sampleRate / 2 else { return "" }
        let text: String
        if let unified {
            text = try await unified.transcribe(squeezed)
        } else if let tdt {
            var state = try TdtDecoderState()
            text = try await tdt.transcribe(squeezed, decoderState: &state).text
        } else {
            throw TranscriptionError.modelNotReady
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds speech with Silero VAD and cuts every long pause down
    /// (`squeezePauses(_:speech:keep:)`). Shared with `Qwen3ASRTranscriber`.
    static func squeezePauses(_ samples: [Float], vad: VadManager) async throws -> [Float] {
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        let ranges = segments.map {
            (start: $0.startSample(sampleRate: sampleRate),
             end: min(samples.count, Int($0.endTime * Double(sampleRate))))
        }
        return squeezePauses(samples, speech: ranges, keep: keptSilence)
    }

    /// One pause-trimming pass over the whole buffer: no cap on speech length,
    /// so only the silences between speech are touched.
    private static let segmentation = VadSegmentationConfig(
        minSilenceDuration: 0.6, maxSpeechDuration: 3600, speechPadding: 0.15
    )

    /// Keeps every speech range and cuts each gap longer than `2 * keep`
    /// samples down to its first and last `keep` samples, so a thinking
    /// pause becomes a short natural one. The tail after the last speech is
    /// kept up to `keep`. With no speech found, the buffer is returned as is
    /// rather than dropped: the VAD can miss quiet speech.
    static func squeezePauses(_ samples: [Float], speech: [(start: Int, end: Int)], keep: Int) -> [Float] {
        guard !speech.isEmpty else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var cursor = 0
        for range in speech {
            let start = max(cursor, min(range.start, samples.count))
            let end = max(start, min(range.end, samples.count))
            let gap = start - cursor
            if gap > keep * 2 {
                out += samples[cursor..<(cursor + keep)]
                out += samples[(start - keep)..<start]
            } else if gap > 0 {
                out += samples[cursor..<start]
            }
            out += samples[start..<end]
            cursor = end
        }
        out += samples[cursor..<min(samples.count, cursor + keep)]
        return out
    }

    /// One second of speech-like multi-tone audio for warm-up.
    static func warmupSamples() -> [Float] {
        let fundamentals: [Float] = [150, 300, 600, 1200]
        return (0..<sampleRate).map { i in
            let t = Float(i) / Float(sampleRate)
            return fundamentals.reduce(0) { acc, f in acc + 0.1 * sin(2.0 * .pi * f * t) }
        }
    }
}
