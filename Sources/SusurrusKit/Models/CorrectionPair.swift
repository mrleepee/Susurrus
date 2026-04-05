import Foundation

/// A correction pair recording a user's edit of a transcription.
/// Used as few-shot examples in the LLM cleanup prompt.
public struct CorrectionPair: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let rawText: String
    public let editedText: String
    public let date: Date

    public init(id: UUID = UUID(), rawText: String, editedText: String, date: Date = Date()) {
        self.id = id
        self.rawText = rawText
        self.editedText = editedText
        self.date = date
    }
}
