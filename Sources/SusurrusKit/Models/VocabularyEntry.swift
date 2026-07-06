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

    public init(
        id: UUID = UUID(),
        term: String,
        category: VocabularyCategory = .custom,
        useCount: Int? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}
