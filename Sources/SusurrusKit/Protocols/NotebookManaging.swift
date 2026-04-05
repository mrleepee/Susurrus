import Foundation

/// Protocol for managing project notebooks.
public protocol NotebookManaging: Sendable {
    /// Get all notebooks.
    func notebooks() -> [Notebook]

    /// Create a new notebook with the given name.
    @discardableResult
    func createNotebook(name: String) -> Notebook

    /// Delete a notebook by ID.
    func deleteNotebook(id: UUID)

    /// Rename a notebook.
    func renameNotebook(id: UUID, newName: String)

    /// Get the active notebook ID (persisted in UserDefaults).
    func activeNotebookId() -> UUID?

    /// Set the active notebook ID. Pass nil to deactivate.
    func setActiveNotebookId(_ id: UUID?)

    /// Append a transcription to the active notebook.
    /// No-op if no notebook is active.
    func appendToActiveNotebook(text: String)

    /// Get a context string for LLM prompt from the active notebook.
    /// Truncated to ~2000 chars from recent entries.
    func activeNotebookContext() -> String

    /// Get entries for a specific notebook.
    func notebookEntries(id: UUID) -> [NotebookEntry]

    /// Delete an entry from a notebook.
    func deleteEntry(notebookId: UUID, entryId: UUID)

    /// Update an entry's text.
    func updateEntry(notebookId: UUID, entryId: UUID, newText: String)
}
