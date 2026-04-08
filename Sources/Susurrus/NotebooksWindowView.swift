import SwiftUI
import SusurrusKit

/// Standalone Notebooks window — accessible from menu bar "Notebooks..." item.
struct NotebooksWindowView: View {
    @State private var notebookList: [Notebook] = []
    @State private var newNotebookName: String = ""
    @State private var selectedNotebookId: UUID?
    @State private var currentEntries: [NotebookEntry] = []
    @State private var editingEntryId: UUID?
    @State private var editingEntryText: String = ""
    @State private var renamingNotebookId: UUID?
    @State private var renameText: String = ""

    var body: some View {
        HSplitView {
            // Left pane: notebook list
            VStack(alignment: .leading, spacing: 0) {
                Text("Notebooks")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if notebookList.isEmpty {
                    Text("No notebooks yet.\nCreate one below.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(notebookList, selection: $selectedNotebookId) { notebook in
                        notebookRow(notebook, manager: manager)
                    }
                    .listStyle(.sidebar)
                }

                Divider()

                HStack {
                    TextField("New notebook", text: $newNotebookName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createNotebook() }
                    Button(action: { createNotebook() }) {
                        Image(systemName: "plus")
                    }
                    .disabled(newNotebookName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

            // Right pane: entries
            entryDetailPane
                .frame(minWidth: 300, idealWidth: 400)
        }
        .frame(minWidth: 550, idealWidth: 700, minHeight: 350, idealHeight: 450)
        .onAppear { loadNotebooks() }
        .onChange(of: selectedNotebookId) { _, _ in
            loadEntries()
            editingEntryId = nil
        }
    }

    private var manager: NotebookManager { NotebookManager() }

    // MARK: - Notebook Row

    @ViewBuilder
    private func notebookRow(_ notebook: Notebook, manager: NotebookManager) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingNotebookId == notebook.id {
                    TextField("Notebook name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                manager.renameNotebook(id: notebook.id, newName: trimmed)
                                loadNotebooks()
                            }
                            renamingNotebookId = nil
                        }
                        .onExitCommand { renamingNotebookId = nil }
                } else {
                    Text(notebook.name)
                        .fontWeight(.medium)
                    Text("\(notebook.entries.count) entries • \(notebook.updatedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.activeNotebookId() == notebook.id {
                Text("Active")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
            Button {
                manager.setActiveNotebookId(notebook.id)
                loadNotebooks()
            } label: {
                Image(systemName: manager.activeNotebookId() == notebook.id ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Set as active notebook")

            Button {
                renameText = notebook.name
                renamingNotebookId = notebook.id
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rename notebook")

            Button {
                manager.deleteNotebook(id: notebook.id)
                if selectedNotebookId == notebook.id {
                    selectedNotebookId = nil
                    currentEntries = []
                }
                loadNotebooks()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Delete notebook")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Entry Detail

    @ViewBuilder
    private var entryDetailPane: some View {
        if let selectedId = selectedNotebookId,
           let notebook = notebookList.first(where: { $0.id == selectedId }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(notebook.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("\(currentEntries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                if currentEntries.isEmpty {
                    Text("No entries yet.\nTranscriptions will appear here when this notebook is active.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List {
                        ForEach(currentEntries) { entry in
                            entryRow(entry, notebookId: notebook.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            VStack {
                Image(systemName: "book")
                    .font(.system(size: 40))
                    .foregroundStyle(.quaternary)
                Text("Select a notebook to view entries")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: NotebookEntry, notebookId: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if entry.isEdited {
                    Text("edited")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()

                if editingEntryId != entry.id {
                    Button {
                        editingEntryId = entry.id
                        editingEntryText = entry.text
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    manager.deleteEntry(notebookId: notebookId, entryId: entry.id)
                    loadEntries()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if editingEntryId == entry.id {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $editingEntryText)
                        .font(.system(size: 13))
                        .frame(minHeight: 80)
                        .border(Color(nsColor: .separatorColor), width: 1)

                    HStack(spacing: 8) {
                        Button("Cancel") { editingEntryId = nil }
                        Button("Save") {
                            manager.updateEntry(notebookId: notebookId, entryId: entry.id, newText: editingEntryText)
                            editingEntryId = nil
                            loadEntries()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingEntryText.isEmpty)
                    }
                }
            } else {
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                if let diff = entry.diffDescription {
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func createNotebook() {
        let name = newNotebookName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let nb = manager.createNotebook(name: name)
        newNotebookName = ""
        loadNotebooks()
        selectedNotebookId = nb.id
    }

    private func loadNotebooks() {
        notebookList = manager.notebooks()
        loadEntries()
    }

    private func loadEntries() {
        guard let id = selectedNotebookId else {
            currentEntries = []
            return
        }
        currentEntries = NotebookEntry.sortedDescending(manager.notebookEntries(id: id))
    }
}
