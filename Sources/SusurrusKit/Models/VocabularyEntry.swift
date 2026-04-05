import Foundation

/// A vocabulary entry with a typed category for context-aware injection
/// into ASR (promptTokens) and LLM cleanup prompts.
public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var term: String
    public var category: VocabularyCategory

    public init(id: UUID = UUID(), term: String, category: VocabularyCategory = .custom) {
        self.id = id
        self.term = term
        self.category = category
    }
}
