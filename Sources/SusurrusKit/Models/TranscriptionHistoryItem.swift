import Foundation

/// A single transcription history entry.
public struct TranscriptionHistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// The raw ASR output before LLM cleanup. nil for items created before F10.
    public let rawText: String?
    public let date: Date

    public init(text: String, rawText: String? = nil, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.rawText = rawText
        self.date = date
    }

    /// Create a copy with updated text (preserves id, rawText, date).
    public func withText(_ newText: String) -> TranscriptionHistoryItem {
        TranscriptionHistoryItem(id: id, text: newText, rawText: rawText, date: date)
    }

    private init(id: UUID, text: String, rawText: String?, date: Date) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.date = date
    }
}
