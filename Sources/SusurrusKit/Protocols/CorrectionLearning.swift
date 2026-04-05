import Foundation

/// Protocol for learning from user edits to transcriptions.
public protocol CorrectionLearning: Sendable {
    /// Record a correction pair (raw transcription -> user-edited text).
    func recordCorrection(raw: String, edited: String)

    /// Get the most relevant correction pairs for a given text.
    func relevantCorrections(for text: String, limit: Int) -> [CorrectionPair]

    /// Get all correction pairs.
    func allCorrections() -> [CorrectionPair]

    /// Clear all corrections.
    func clearCorrections()

    /// Format correction pairs as few-shot examples for LLM prompt.
    func fewShotString(for text: String, limit: Int) -> String
}
