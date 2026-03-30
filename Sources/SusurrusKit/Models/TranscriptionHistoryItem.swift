import Foundation

/// A single transcription history entry.
public struct TranscriptionHistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date

    public init(text: String, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.date = date
    }
}
