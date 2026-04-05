import Foundation

/// Manages notebooks persisted as JSON files in Application Support.
public final class NotebookManager: NotebookManaging, @unchecked Sendable {
    private let baseURL: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.susurrus.notebook", attributes: .concurrent)

    private static let activeNotebookKey = "activeNotebookId"

    /// Context truncation limit in characters for LLM prompt injection.
    public static let contextCharLimit = 2000

    public init(defaults: UserDefaults = .standard, baseURL: URL? = nil) {
        self.defaults = defaults

        if let baseURL {
            self.baseURL = baseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseURL = appSupport.appendingPathComponent("Susurrus/Notebooks", isDirectory: true)
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
    }

    /// Factory for testing with a temp directory.
    public static func createForTesting() -> NotebookManager {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("susurrus-notebook-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let d = UserDefaults(suiteName: "com.susurrus.notebook.test.\(UUID().uuidString)")!
        return NotebookManager(defaults: d, baseURL: tmp)
    }

    // MARK: - CRUD

    public func notebooks() -> [Notebook] {
        queue.sync {
            loadIndex()
        }
    }

    @discardableResult
    public func createNotebook(name: String) -> Notebook {
        let notebook = Notebook(name: name)
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            index.append(notebook)
            saveIndex(index)
            saveNotebook(notebook)
        }
        return notebook
    }

    public func deleteNotebook(id: UUID) {
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            index.removeAll { $0.id == id }
            saveIndex(index)
            // Remove file
            let fileURL = notebookURL(id: id)
            try? FileManager.default.removeItem(at: fileURL)
        }
        // Clear active if deleted
        if activeNotebookId() == id {
            setActiveNotebookId(nil)
        }
    }

    public func renameNotebook(id: UUID, newName: String) {
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            if let i = index.firstIndex(where: { $0.id == id }) {
                index[i].name = newName
                index[i].updatedAt = Date()
                saveIndex(index)
                saveNotebook(index[i])
            }
        }
    }

    // MARK: - Active notebook

    public func activeNotebookId() -> UUID? {
        guard let idString = defaults.string(forKey: Self.activeNotebookKey) else { return nil }
        return UUID(uuidString: idString)
    }

    public func setActiveNotebookId(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeNotebookKey)
        } else {
            defaults.removeObject(forKey: Self.activeNotebookKey)
        }
    }

    public func appendToActiveNotebook(text: String) {
        guard let activeId = activeNotebookId() else { return }
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            guard let i = index.firstIndex(where: { $0.id == activeId }) else { return }
            let entry = NotebookEntry(text: text)
            index[i].entries.append(entry)
            index[i].updatedAt = Date()
            saveIndex(index)
            saveNotebook(index[i])
        }
    }

    public func activeNotebookContext() -> String {
        guard let activeId = activeNotebookId() else { return "" }
        let notebook = queue.sync { () -> Notebook? in
            let index = loadIndex()
            return index.first(where: { $0.id == activeId })
        }
        guard let notebook else { return "" }

        let entries = notebook.entries.suffix(10)
        guard !entries.isEmpty else { return "" }

        let fullContext = "Project: \(notebook.name)\n" + entries.map { entry in
            "- \(entry.text)"
        }.joined(separator: "\n")

        if fullContext.count > Self.contextCharLimit {
            return String(fullContext.suffix(Self.contextCharLimit))
        }
        return fullContext
    }

    // MARK: - Entry management

    public func notebookEntries(id: UUID) -> [NotebookEntry] {
        queue.sync {
            loadIndex().first(where: { $0.id == id })?.entries ?? []
        }
    }

    public func deleteEntry(notebookId: UUID, entryId: UUID) {
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            guard let i = index.firstIndex(where: { $0.id == notebookId }) else { return }
            index[i].entries.removeAll { $0.id == entryId }
            index[i].updatedAt = Date()
            saveIndex(index)
            saveNotebook(index[i])
        }
    }

    public func updateEntry(notebookId: UUID, entryId: UUID, newText: String) {
        queue.sync(flags: .barrier) {
            var index = loadIndex()
            guard let ni = index.firstIndex(where: { $0.id == notebookId }) else { return }
            guard let ei = index[ni].entries.firstIndex(where: { $0.id == entryId }) else { return }
            index[ni].entries[ei] = NotebookEntry(id: entryId, text: newText, date: index[ni].entries[ei].date)
            index[ni].updatedAt = Date()
            saveIndex(index)
            saveNotebook(index[ni])
        }
    }

    // MARK: - Persistence

    private func notebookURL(id: UUID) -> URL {
        baseURL.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        baseURL.appendingPathComponent("index.json")
    }

    private func loadIndex() -> [Notebook] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([Notebook].self, from: data)) ?? []
    }

    private func saveIndex(_ notebooks: [Notebook]) {
        guard let data = try? JSONEncoder().encode(notebooks) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func saveNotebook(_ notebook: Notebook) {
        guard let data = try? JSONEncoder().encode(notebook) else { return }
        try? data.write(to: notebookURL(id: notebook.id), options: .atomic)
    }
}
