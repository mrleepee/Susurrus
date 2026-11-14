import Foundation

/// Everything between raw ASR text and the text the user gets:
/// deterministic corrector (Layer 1) → spoken formatting (slash commands,
/// lists) → optional LLM polish (Layer 2), guarded → corrector and
/// formatting re-pass on accepted LLM output.
///
/// Pure with respect to app state: vocabulary and rules are passed in, and
/// nothing is recorded. The caller credits `changes` (fires, fixes) and
/// surfaces `llm` failures — so the app's stop path and the eval harness run
/// the same transformation and only the app has side effects.
public struct TranscriptFinalizer: Sendable {

    /// Optional Layer 2. `systemPrompt` receives the corrected text, because
    /// the prompt's vocabulary context and few-shot examples are chosen by
    /// relevance to it.
    public struct LLMStage: Sendable {
        public let processor: any LLMProcessing
        public let systemPrompt: @Sendable (String) -> String

        public init(processor: any LLMProcessing, systemPrompt: @escaping @Sendable (String) -> String) {
            self.processor = processor
            self.systemPrompt = systemPrompt
        }
    }

    public enum LLMOutcome: Equatable, Sendable {
        case skipped
        case accepted
        /// The guardrail rejected the output as drifted from the input.
        case rejected(output: String)
        case failed(String)
    }

    public struct Result: Equatable, Sendable {
        /// The text to deliver.
        public let text: String
        /// After Layer 1 and spoken formatting, before any LLM pass.
        public let corrected: String
        /// Changes from the first corrector pass only. That pass is the one
        /// credited: counting the post-LLM re-pass too would make fire counts
        /// incomparable between LLM-on and LLM-off runs.
        public let changes: [CorrectionChange]
        public let llm: LLMOutcome
    }

    private let corrector: any TranscriptCorrecting

    public init(corrector: any TranscriptCorrecting = TranscriptCorrector()) {
        self.corrector = corrector
    }

    public func finalize(
        _ raw: String,
        vocabulary: [VocabularyEntry],
        rules: [CorrectionRule],
        formatter: SpokenFormatter? = nil,
        llm: LLMStage? = nil
    ) async -> Result {
        guard !raw.isEmpty else {
            return Result(text: "", corrected: "", changes: [], llm: .skipped)
        }

        let outcome = corrector.correct(raw, vocabulary: vocabulary, rules: rules)
        // After the corrector, so learned rules keep matching the spoken
        // words they were learned from ("slash", "one").
        let corrected = formatter?.format(outcome.text) ?? outcome.text

        guard let llm else {
            return Result(text: corrected, corrected: corrected, changes: outcome.changes, llm: .skipped)
        }

        do {
            let output = try await llm.processor.process(text: corrected, systemPrompt: llm.systemPrompt(corrected))
            guard TranscriptGuardrail.accepts(input: corrected, output: output) else {
                return Result(text: corrected, corrected: corrected, changes: outcome.changes, llm: .rejected(output: output))
            }
            // Re-run the deterministic pass so vocabulary casing and spelling
            // survive any LLM meddling.
            let recorrected = corrector.correct(output, vocabulary: vocabulary, rules: rules).text
            let polished = formatter?.format(recorrected) ?? recorrected
            return Result(text: polished, corrected: corrected, changes: outcome.changes, llm: .accepted)
        } catch {
            return Result(text: corrected, corrected: corrected, changes: outcome.changes, llm: .failed(error.localizedDescription))
        }
    }
}
