import Foundation

/// A named notebook that accumulates transcriptions as project context.
public struct Notebook: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [NotebookEntry]

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.entries = []
    }
}

/// A single entry in a notebook.
public struct NotebookEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    /// The original transcription text before any manual edit. Nil if never edited.
    public var originalText: String?
    public var date: Date
    /// When this entry was last manually edited. Nil if never edited.
    public var editedDate: Date?

    public init(id: UUID = UUID(), text: String, originalText: String? = nil, date: Date = Date(), editedDate: Date? = nil) {
        self.id = id
        self.text = text
        self.originalText = originalText
        self.date = date
        self.editedDate = editedDate
    }

    /// Whether this entry has been manually edited.
    public var isEdited: Bool { originalText != nil }

    /// Human-readable diff for display: "{original → edited}" for changed words.
    public var diffDescription: String? {
        guard let original = originalText, original != text else { return nil }
        return "{\(original) → \(text)}"
    }

    /// Returns entries sorted newest first.
    public static func sortedDescending(_ entries: [NotebookEntry]) -> [NotebookEntry] {
        entries.sorted { $0.date > $1.date }
    }
}
