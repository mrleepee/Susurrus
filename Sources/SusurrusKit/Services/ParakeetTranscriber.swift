import FluidAudio
import Foundation

/// Stop-time transcription with NVIDIA Parakeet TDT 0.6B v2 (English) on the
/// Neural Engine, via FluidAudio.
///
/// Long pauses are cut down first with Silero VAD: given several seconds of
/// room tone, every model tried invents words (Whisper "thank you" / "you",
/// Parakeet repetition loops like "put it in put it in"). On the read-aloud
/// set with stretched pauses, VAD + Parakeet + the corrector matched
/// large-v3's word accuracy with fewer formatting errors, at about 0.2 s per
/// minute of audio instead of about 15 s. See docs/eval-harness.md.
public actor ParakeetTranscriber {

    /// Model-picker id. The live preview still runs on Whisper (`previewWhisperModel`).
    public static let modelID = "parakeet-v2"

    /// Whisper model that drives capture and the live preview overlay while
    /// Parakeet does the final transcription.
    public static let previewWhisperModel = "small"

    /// Folder name recorded with captured clips.
    public static let modelFolderName = "parakeet-tdt-0.6b-v2"

    public static func isParakeet(_ modelName: String) -> Bool {
        modelName == modelID
    }

    /// Whether the Parakeet models are already on disk (no download needed).
    public static func isCached() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

    /// Room tone kept at each side of a squeezed pause, in samples (0.3 s).
    static let keptSilence = 4_800

    private static let sampleRate = 16_000

    private var asr: AsrManager?
    private var vad: VadManager?

    public init() {}

    /// Downloads (first use only, ~480 MB) and loads Parakeet and Silero VAD,
    /// then runs one warm-up pass so the Neural Engine compile cost lands here.
    public func load(onDownloadProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let models = try await AsrModels.downloadAndLoad(
            version: .v2,
            progressHandler: { progress in onDownloadProgress?(progress.fractionCompleted) }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let vadManager = try await VadManager()
        asr = manager
        vad = vadManager
        _ = try? await transcribe(samples: Self.warmupSamples())
    }

    public var isLoaded: Bool { asr != nil }

    /// Transcribes a 16 kHz mono buffer: squeeze pauses, then one Parakeet pass.
    public func transcribe(samples: [Float]) async throws -> String {
        guard let asr, let vad else { throw TranscriptionError.modelNotReady }
        let segments = try await vad.segmentSpeech(samples, config: Self.segmentation)
        let ranges = segments.map {
            (start: $0.startSample(sampleRate: Self.sampleRate),
             end: min(samples.count, Int($0.endTime * Double(Self.sampleRate))))
        }
        let squeezed = Self.squeezePauses(samples, speech: ranges, keep: Self.keptSilence)
        guard squeezed.count >= Self.sampleRate / 2 else { return "" }
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(squeezed, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private static func warmupSamples() -> [Float] {
        let fundamentals: [Float] = [150, 300, 600, 1200]
        return (0..<sampleRate).map { i in
            let t = Float(i) / Float(sampleRate)
            return fundamentals.reduce(0) { acc, f in acc + 0.1 * sin(2.0 * .pi * f * t) }
        }
    }
}
