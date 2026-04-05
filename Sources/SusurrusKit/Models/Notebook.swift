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
    public let text: String
    public let date: Date

    public init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}
