import Foundation

/// Which layer produced a correction. Lets the caller credit the specific
/// rule or vocabulary entry that fired, so effectiveness can be measured
/// rather than assumed.
public enum CorrectionOrigin: Equatable, Sendable {
    case rule(UUID)
    case vocabulary(UUID)
}

/// A single applied correction, for logging and history.
public struct CorrectionChange: Equatable, Sendable {
    public let original: String
    public let corrected: String
    /// Nil for changes made before provenance tracking, or by other correctors.
    public let origin: CorrectionOrigin?

    public init(original: String, corrected: String, origin: CorrectionOrigin? = nil) {
        self.original = original
        self.corrected = corrected
        self.origin = origin
    }

    public var firedRuleID: UUID? {
        if case .rule(let id) = origin { return id }
        return nil
    }

    public var firedVocabularyID: UUID? {
        if case .vocabulary(let id) = origin { return id }
        return nil
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
