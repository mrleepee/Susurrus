import Foundation

/// A vocabulary entry with a typed category for context-aware injection
/// into ASR (promptTokens) and LLM cleanup prompts.
public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var term: String
    public var category: VocabularyCategory
    /// Sessions in which this term appeared in the final text. Optional so
    /// entries persisted before usage tracking still decode.
    public var useCount: Int?
    public var lastUsedAt: Date?
    /// Sessions in which the corrector had to *repair* this term. Read against
    /// `useCount`: high use with zero fixes means Whisper is getting the term
    /// right unaided, which is prompt-bias working at the source.
    public var fixCount: Int?
    /// When the term entered the vocabulary. Stamped by `addEntry`, so entries
    /// persisted before this existed decode as nil and are simply treated as
    /// established — see `VocabularyRanker`'s grace tier.
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        term: String,
        category: VocabularyCategory = .custom,
        useCount: Int? = nil,
        lastUsedAt: Date? = nil,
        fixCount: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.fixCount = fixCount
        self.createdAt = createdAt
    }
}
