import Foundation

/// A single applied correction, for logging and history.
public struct CorrectionChange: Equatable, Sendable {
    public let original: String
    public let corrected: String

    public init(original: String, corrected: String) {
        self.original = original
        self.corrected = corrected
    }
}

/// Result of a deterministic correction pass.
public struct CorrectionOutcome: Equatable, Sendable {
    public let text: String
    public let changes: [CorrectionChange]

    public init(text: String, changes: [CorrectionChange]) {
        self.text = text
        self.changes = changes
    }
}

/// Protocol for the deterministic transcript corrector: applies learned
/// replacement rules and fuzzy vocabulary matching to a final transcript.
public protocol TranscriptCorrecting: Sendable {
    func correct(
        _ text: String,
        vocabulary: [VocabularyEntry],
        rules: [CorrectionRule]
    ) -> CorrectionOutcome
}
