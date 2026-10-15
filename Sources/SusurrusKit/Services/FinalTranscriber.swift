import Foundation
@preconcurrency import WhisperKit

/// Settings for the stop-time whole-buffer decode. `production` is what the
/// app ships; the eval harness varies the fields to compare configurations.
public struct FinalDecodeConfig: Codable, Equatable, Sendable {
    public enum Chunking: String, Codable, Sendable {
        /// WhisperKit's VAD chunker: >30 s buffers split at the longest
        /// silence in each window's second half, chunks decoded in parallel.
        case vad
        /// WhisperKit's sequential seek over 30 s windows.
        case none
    }

    public var chunking: Chunking
    public var concurrentWorkerCount: Int
    /// Hard cap on vocabulary prompt tokens. Prompt tokens are prefilled
    /// sequentially through the decoder on every decode, so an uncapped
    /// vocabulary adds seconds of constant overhead per pass.
    public var maxPromptTokens: Int

    public static let production = FinalDecodeConfig()

    public init(chunking: Chunking = .vad, concurrentWorkerCount: Int = 4, maxPromptTokens: Int = 48) {
        self.chunking = chunking
        self.concurrentWorkerCount = concurrentWorkerCount
        self.maxPromptTokens = maxPromptTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FinalDecodeConfig()
        chunking = try c.decodeIfPresent(Chunking.self, forKey: .chunking) ?? d.chunking
        concurrentWorkerCount = try c.decodeIfPresent(Int.self, forKey: .concurrentWorkerCount) ?? d.concurrentWorkerCount
        maxPromptTokens = try c.decodeIfPresent(Int.self, forKey: .maxPromptTokens) ?? d.maxPromptTokens
    }

    /// Decoding options for the final pass, before prompt tokens are added.
    /// `language` is fixed (not nil): `language: nil` makes WhisperKit run a
    /// language-detection pass before every decode.
    func decodingOptions(language: String) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: chunking == .vad ? .vad : nil
        )
    }
}

/// One decoded segment with Whisper's own quality signals, kept so the
/// harness can test whether low-confidence segments predict errors.
public struct FinalSegment: Codable, Equatable, Sendable {
    public var text: String
    public var start: Float
    public var end: Float
    public var avgLogprob: Float
    public var noSpeechProb: Float
    public var compressionRatio: Float
    public var temperature: Float
}

/// Result of the stop-time decode.
public struct FinalTranscript: Sendable {
    public enum Outcome: String, Codable, Sendable {
        case decoded
        /// Under `FinalTranscriber.minSamples` — nothing worth decoding.
        case tooShort
        /// Peak below `FinalTranscriber.silencePeak` — skipped before decode.
        case silent
        /// Decoded, but nothing survived noise stripping.
        case empty
        case failed
    }

    public var outcome: Outcome
    /// Noise-stripped text; empty unless `outcome == .decoded`.
    public var text: String
    /// Terms that made it into the prompt-token budget, in rank order.
    public var promptTerms: [String]
    public var promptTokenCount: Int
    public var segments: [FinalSegment]
    public var decodeMs: Int
    public var failure: String?

    static func skipped(_ outcome: Outcome, promptTerms: [String] = [], promptTokenCount: Int = 0) -> FinalTranscript {
        FinalTranscript(outcome: outcome, text: "", promptTerms: promptTerms,
                        promptTokenCount: promptTokenCount, segments: [], decodeMs: 0, failure: nil)
    }
}

/// The stop-time decode: prompt-token packing plus one whole-buffer batch
/// decode. Shared by `StreamingTranscriptionService` (the app's stop path)
/// and the eval harness, so the harness measures the code that ships.
enum FinalTranscriber {

    static let sampleRate = 16_000

    /// Minimum buffer worth transcribing (0.5 s).
    static let minSamples = 8_000

    /// Peak amplitude below which the whole buffer is treated as silence and
    /// the decode is skipped.
    static let silencePeak: Float = 0.015

    /// Packs terms in rank order until `budget` tokens are used. A term that
    /// doesn't fit is skipped, never truncated mid-token, and later (shorter)
    /// terms may still fit after it.
    static func packPromptTokens(
        terms: [String],
        budget: Int,
        encode: (String) -> [Int]
    ) -> (tokens: [Int], chosen: [String]) {
        var chosen: [String] = []
        var tokens: [Int] = []
        for term in terms {
            let encoded = encode((chosen + [term]).joined(separator: ", "))
            if encoded.count > budget { continue }
            chosen.append(term)
            tokens = encoded
        }
        return (tokens, chosen)
    }

    /// Decodes `samples` with `options` (prompt tokens already applied).
    static func decode(
        samples: [Float],
        whisperKit: WhisperKit,
        options: DecodingOptions,
        promptTerms: [String],
        wordTimestamps: Bool,
        trace: @Sendable (String) -> Void
    ) async -> FinalTranscript {
        let promptCount = options.promptTokens?.count ?? 0
        guard samples.count >= minSamples else {
            return .skipped(.tooShort, promptTerms: promptTerms, promptTokenCount: promptCount)
        }

        let seconds = Double(samples.count) / Double(sampleRate)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        trace("flush: whole-buffer decode of \(String(format: "%.1f", seconds))s (peak \(String(format: "%.3f", peak)))")
        guard peak >= silencePeak else {
            return .skipped(.silent, promptTerms: promptTerms, promptTokenCount: promptCount)
        }

        var effective = options
        if wordTimestamps { effective.wordTimestamps = true }

        let start = Date()
        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: effective)
        } catch {
            trace("flush: decode failed: \(error)")
            var failed = FinalTranscript.skipped(.failed, promptTerms: promptTerms, promptTokenCount: promptCount)
            failed.failure = "\(error)"
            return failed
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        trace("decode: \(String(format: "%.1f", seconds))s audio in \(ms)ms (promptTokens=\(promptCount), wordTimestamps=\(wordTimestamps))")

        if wordTimestamps {
            let words = results.flatMap(\.segments).compactMap(\.words).flatMap { $0 }
            if !words.isEmpty {
                let line = words
                    .map { "[\(String(format: "%.2f", $0.probability))]\($0.word.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: " ")
                let mean = words.map(\.probability).reduce(0, +) / Float(words.count)
                trace("confidence: mean=\(String(format: "%.2f", mean)) \(line)")
            }
        }

        let raw = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = StreamingTranscriptionService.stripNoiseTokens(from: raw)
        let segments = results.flatMap(\.segments).map {
            FinalSegment(
                text: StreamingTranscriptionService.stripNoiseTokens(from: $0.text),
                start: $0.start, end: $0.end,
                avgLogprob: $0.avgLogprob, noSpeechProb: $0.noSpeechProb,
                compressionRatio: $0.compressionRatio, temperature: $0.temperature
            )
        }
        return FinalTranscript(
            outcome: cleaned.isEmpty ? .empty : .decoded,
            text: cleaned,
            promptTerms: promptTerms,
            promptTokenCount: promptCount,
            segments: segments,
            decodeMs: ms,
            failure: nil
        )
    }
}
