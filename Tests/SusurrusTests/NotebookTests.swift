import Testing
@testable import SusurrusKit

@Suite("Notebook Tests")
struct NotebookTests {

    private func makeManager() -> NotebookManager {
        NotebookManager.createForTesting()
    }

    @Test("Create notebook")
    func createNotebook() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Test Notebook")
        let all = manager.notebooks()
        #expect(all.count == 1)
        #expect(all[0].name == "Test Notebook")
        #expect(all[0].entries.isEmpty)
    }

    @Test("Delete notebook")
    func deleteNotebook() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Delete Me")
        manager.deleteNotebook(id: nb.id)
        #expect(manager.notebooks().isEmpty)
    }

    @Test("Rename notebook")
    func renameNotebook() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Old Name")
        manager.renameNotebook(id: nb.id, newName: "New Name")
        let updated = manager.notebooks().first(where: { $0.id == nb.id })
        #expect(updated?.name == "New Name")
    }

    @Test("Append to active notebook")
    func appendToActive() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Active")
        manager.setActiveNotebookId(nb.id)
        manager.appendToActiveNotebook(text: "First entry")
        manager.appendToActiveNotebook(text: "Second entry")
        let entries = manager.notebookEntries(id: nb.id)
        #expect(entries.count == 2)
        #expect(entries[0].text == "First entry")
        #expect(entries[1].text == "Second entry")
    }

    @Test("Append with no active notebook is no-op")
    func appendWithNoActive() {
        let manager = makeManager()
        manager.appendToActiveNotebook(text: "This should not appear")
        // No crash, no entries
        #expect(manager.notebooks().isEmpty)
    }

    @Test("Active notebook context for LLM prompt")
    func activeNotebookContext() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Project")
        manager.setActiveNotebookId(nb.id)
        manager.appendToActiveNotebook(text: "We need to update the SOW.")
        manager.appendToActiveNotebook(text: "The deadline is end of month.")
        let context = manager.activeNotebookContext()
        #expect(context.contains("Project"))
        #expect(context.contains("SOW"))
        #expect(context.contains("deadline"))
    }

    @Test("Empty notebook gives empty context")
    func emptyNotebookContext() {
        let manager = makeManager()
        #expect(manager.activeNotebookContext() == "")
    }

    @Test("Context truncated at char limit")
    func contextTruncation() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Long")
        manager.setActiveNotebookId(nb.id)
        // Add entries that exceed the limit
        let longText = String(repeating: "This is a very long entry that should be truncated. ", count: 100)
        manager.appendToActiveNotebook(text: longText)
        let context = manager.activeNotebookContext()
        #expect(context.count <= NotebookManager.contextCharLimit)
    }

    @Test("Set active to nil clears it")
    func setActiveNil() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Temp")
        manager.setActiveNotebookId(nb.id)
        #expect(manager.activeNotebookId() != nil)
        manager.setActiveNotebookId(nil)
        #expect(manager.activeNotebookId() == nil)
    }

    @Test("Delete entry from notebook")
    func deleteEntry() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Entries")
        manager.setActiveNotebookId(nb.id)
        manager.appendToActiveNotebook(text: "Keep")
        manager.appendToActiveNotebook(text: "Delete")
        var entries = manager.notebookEntries(id: nb.id)
        #expect(entries.count == 2)
        manager.deleteEntry(notebookId: nb.id, entryId: entries[1].id)
        entries = manager.notebookEntries(id: nb.id)
        #expect(entries.count == 1)
        #expect(entries[0].text == "Keep")
    }

    @Test("Update entry text")
    func updateEntry() {
        let manager = makeManager()
        let nb = manager.createNotebook(name: "Edit")
        manager.setActiveNotebookId(nb.id)
        manager.appendToActiveNotebook(text: "Original")
        let entry = manager.notebookEntries(id: nb.id).first!
        manager.updateEntry(notebookId: nb.id, entryId: entry.id, newText: "Updated")
        let updated = manager.notebookEntries(id: nb.id).first!
        #expect(updated.text == "Updated")
    }
}
