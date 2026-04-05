import Foundation

/// Concrete vocabulary manager persisting to UserDefaults.
/// Supports both flat words (legacy) and categorized entries (F9).
/// Automatically migrates flat words to categorized entries on first access.
public final class VocabularyManager: VocabularyManaging, @unchecked Sendable {
    private let defaults: UserDefaults
    private let flatKey = "vocabularyWords"
    private let entriesKey = "vocabularyEntries"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateIfNeeded()
    }

    /// Factory for testing with an isolated UserDefaults suite.
    public static func createForTesting() -> VocabularyManager {
        VocabularyManager(defaults: UserDefaults(suiteName: "com.susurrus.vocab.test.\(UUID().uuidString)")!)
    }

    // MARK: - Legacy flat-word API

    public func vocabularyWords() -> [String] {
        entries().map(\.term)
    }

    public func setVocabularyWords(_ words: [String]) {
        let newEntries = words.map { VocabularyEntry(term: $0, category: .custom) }
        setEntries(newEntries)
    }

    public func promptString() -> String {
        entries().map(\.term).joined(separator: ", ")
    }

    // MARK: - Categorized entries API

    public func entries() -> [VocabularyEntry] {
        guard let data = defaults.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
    }

    public func setEntries(_ entries: [VocabularyEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: entriesKey)
    }

    public func addEntry(_ entry: VocabularyEntry) {
        var current = entries()
        current.append(entry)
        setEntries(current)
    }

    public func removeEntry(id: UUID) {
        var current = entries()
        current.removeAll { $0.id == id }
        setEntries(current)
    }

    public func llmContextString() -> String {
        let all = entries()
        guard !all.isEmpty else { return "" }

        return all.map { entry in
            "\"\(entry.term)\" \(entry.category.llmInstruction)"
        }.joined(separator: ". ") + "."
    }

    // MARK: - Migration

    /// Migrate flat vocabulary words to categorized entries if needed.
    /// Runs once on init. After migration, deletes the old key.
    private func migrateIfNeeded() {
        // Already migrated
        if defaults.data(forKey: entriesKey) != nil { return }

        // Check for legacy flat words
        let flatWords = defaults.stringArray(forKey: flatKey) ?? []
        guard !flatWords.isEmpty else {
            // No legacy data — initialize with empty entries
            setEntries([])
            return
        }

        // Migrate each word to a custom-category entry
        let migrated = flatWords.map { VocabularyEntry(term: $0, category: .custom) }
        setEntries(migrated)
        defaults.removeObject(forKey: flatKey)
    }
}
