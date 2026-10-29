import Foundation
import Testing
@testable import SusurrusKit

@Suite("FinalTranscriber — prompt packing and config")
struct FinalTranscriberTests {

    /// One token per character keeps budget arithmetic obvious.
    private func encode(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }

    @Test("Terms pack in rank order joined by comma-space")
    func packsInOrder() {
        let packed = FinalTranscriber.packPromptTokens(terms: ["Ab", "Cd"], budget: 48, encode: encode)
        #expect(packed.chosen == ["Ab", "Cd"])
        #expect(packed.tokens == encode("Ab, Cd"))
    }

    @Test("A term that doesn't fit is skipped, and a later shorter term still fits")
    func skipsWithoutTruncating() {
        // "Alpha" = 5; "Alpha, Bravissimo" = 17 > 10; "Alpha, Co" = 9.
        let packed = FinalTranscriber.packPromptTokens(terms: ["Alpha", "Bravissimo", "Co"], budget: 10, encode: encode)
        #expect(packed.chosen == ["Alpha", "Co"])
        #expect(packed.tokens.count == 9)
    }

    @Test("Nothing fits: empty tokens, no terms")
    func nothingFits() {
        let packed = FinalTranscriber.packPromptTokens(terms: ["Supercalifragilistic"], budget: 4, encode: encode)
        #expect(packed.chosen.isEmpty)
        #expect(packed.tokens.isEmpty)
    }

    @Test("Production config matches the options the app shipped before extraction")
    func productionConfig() {
        let options = FinalDecodeConfig.production.decodingOptions(language: "en")
        #expect(options.language == "en")
        #expect(options.concurrentWorkerCount == 4)
        #expect(options.chunkingStrategy == .vad)
        #expect(options.promptTokens == nil)
        #expect(FinalDecodeConfig.production.maxPromptTokens == 48)
    }

    @Test("Config decodes with defaults for missing keys")
    func configDecodesPartially() throws {
        let config = try JSONDecoder().decode(FinalDecodeConfig.self, from: Data(#"{"chunking":"none"}"#.utf8))
        #expect(config.chunking == .none)
        #expect(config.concurrentWorkerCount == 4)
        #expect(config.decodingOptions(language: "en").chunkingStrategy == nil)
    }

    @Test("Large-v3 family ships promptless; other models keep the 48-token prompt")
    func perModelPromptPolicy() {
        for model in ["openai_whisper-large-v3", "openai_whisper-large-v3_turbo",
                      "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3-v20240930_turbo_632MB"] {
            #expect(FinalDecodeConfig.production(forModel: model).maxPromptTokens == 0)
        }
        for model in ["openai_whisper-small", "openai_whisper-base", "openai_whisper-medium", "distil-whisper_distil-large-v3"] {
            #expect(FinalDecodeConfig.production(forModel: model) == .production)
        }
    }
}

@Suite("Prompt failure detection Tests")
struct PromptFailureDetectionTests {
    private func segment(_ text: String, temperature: Float) -> FinalSegment {
        FinalSegment(text: text, start: 0, end: 10, avgLogprob: -0.2, noSpeechProb: 0, compressionRatio: 1.4, temperature: temperature)
    }
    private func transcript(_ outcome: FinalTranscript.Outcome, _ segments: [FinalSegment]) -> FinalTranscript {
        FinalTranscript(outcome: outcome, text: segments.map(\.text).joined(separator: " "), promptTerms: [],
                        promptTokenCount: 10, segments: segments, decodeMs: 0, failure: nil)
    }

    @Test("Empty output counts as a failed prompted decode")
    func emptyOutcome() {
        #expect(FinalTranscriber.promptMayHaveFailed(transcript(.empty, [])))
    }

    @Test("A window left empty at the last fallback counts as failed")
    func exhaustedWindow() {
        let t = transcript(.decoded, [segment("Hello there.", temperature: 0), segment("", temperature: 1)])
        #expect(FinalTranscriber.promptMayHaveFailed(t))
    }

    @Test("A clean decode, or silence skipped before decoding, does not retry")
    func noRetry() {
        #expect(!FinalTranscriber.promptMayHaveFailed(transcript(.decoded, [segment("Hello.", temperature: 0)])))
        #expect(!FinalTranscriber.promptMayHaveFailed(transcript(.silent, [])))
    }
}
