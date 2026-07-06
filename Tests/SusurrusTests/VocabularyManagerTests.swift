import Foundation
import Testing
@testable import SusurrusKit

@Suite("VocabularyManager Tests")
struct VocabularyManagerTests {

    private func makeManager() -> VocabularyManager {
        VocabularyManager.createForTesting()
    }

    // MARK: - Entries CRUD

    @Test("Starts empty with createForTesting")
    func startsEmpty() {
        let manager = makeManager()
        #expect(manager.entries().isEmpty)
    }

    @Test("addEntry appends an entry")
    func addEntry() {
        let manager = makeManager()
        let entry = VocabularyEntry(term: "MarkLogic", category: .technical)
        manager.addEntry(entry)
        #expect(manager.entries().count == 1)
        #expect(manager.entries()[0].term == "MarkLogic")
        #expect(manager.entries()[0].category == .technical)
    }

    @Test("removeEntry deletes by id")
    func removeEntry() {
        let manager = makeManager()
        let entry = VocabularyEntry(term: "SPARQL", category: .technical)
        manager.addEntry(entry)
        #expect(manager.entries().count == 1)
        manager.removeEntry(id: entry.id)
        #expect(manager.entries().isEmpty)
    }

    @Test("removeEntry with unknown id does nothing")
    func removeEntryUnknownId() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "Test"))
        manager.removeEntry(id: UUID())
        #expect(manager.entries().count == 1)
    }

    @Test("setEntries replaces all entries")
    func setEntries() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "Old"))
        let newEntries = [
            VocabularyEntry(term: "A", category: .person),
            VocabularyEntry(term: "B", category: .product),
        ]
        manager.setEntries(newEntries)
        #expect(manager.entries().count == 2)
        #expect(manager.entries()[0].term == "A")
        #expect(manager.entries()[1].term == "B")
    }

    // MARK: - Legacy flat-word API

    @Test("vocabularyWords returns terms from entries")
    func vocabularyWordsReturnsTerms() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "Alpha"))
        manager.addEntry(VocabularyEntry(term: "Beta"))
        #expect(manager.vocabularyWords() == ["Alpha", "Beta"])
    }

    @Test("setVocabularyWords creates custom-category entries")
    func setVocabularyWordsCreatesEntries() {
        let manager = makeManager()
        manager.setVocabularyWords(["one", "two", "three"])
        let entries = manager.entries()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.category == .custom })
        #expect(entries.map(\.term) == ["one", "two", "three"])
    }

    @Test("promptString joins terms with comma and space")
    func promptString() {
        let manager = makeManager()
        manager.setVocabularyWords(["foo", "bar"])
        #expect(manager.promptString() == "foo, bar")
    }

    @Test("promptString returns empty string when no entries")
    func promptStringEmpty() {
        let manager = makeManager()
        #expect(manager.promptString() == "")
    }

    // MARK: - llmContextString

    @Test("llmContextString returns formatted context")
    func llmContextString() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        let context = manager.llmContextString()
        #expect(context.contains("MarkLogic"))
        #expect(context.contains("technical"))
        #expect(context.hasSuffix("."))
    }

    @Test("llmContextString returns empty when no entries")
    func llmContextStringEmpty() {
        let manager = makeManager()
        #expect(manager.llmContextString() == "")
    }

    // MARK: - CSV Export

    @Test("exportCSV produces header and rows")
    func exportCSV() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        manager.addEntry(VocabularyEntry(term: "Balvinder", category: .person))
        let csv = manager.exportCSV()
        let lines = csv.components(separatedBy: .newlines)
        #expect(lines[0] == "Word,Category")
        #expect(lines[1] == "MarkLogic,Technical")
        #expect(lines[2] == "Balvinder,Person")
    }

    @Test("exportCSV wraps terms with commas in quotes")
    func exportCSVQuotesCommas() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "hello, world", category: .custom))
        let csv = manager.exportCSV()
        let lines = csv.components(separatedBy: .newlines)
        #expect(lines[1] == "\"hello, world\",Custom")
    }

    @Test("exportCSV with empty entries returns header only")
    func exportCSVEmpty() {
        let manager = makeManager()
        let csv = manager.exportCSV()
        #expect(csv == "Word,Category")
    }

    // MARK: - CSV Import

    @Test("importCSV imports entries with categories")
    func importCSV() {
        let manager = makeManager()
        let csv = """
        Word,Category
        MarkLogic,Technical
        Balvinder,Person
        """
        let count = manager.importCSV(csv)
        #expect(count == 2)
        let entries = manager.entries()
        #expect(entries.count == 2)
        #expect(entries[0].term == "MarkLogic")
        #expect(entries[0].category == .technical)
        #expect(entries[1].term == "Balvinder")
        #expect(entries[1].category == .person)
    }

    @Test("importCSV handles quoted fields")
    func importCSVQuotedFields() {
        let manager = makeManager()
        let csv = """
        Word,Category
        "hello, world",Custom
        """
        let count = manager.importCSV(csv)
        #expect(count == 1)
        #expect(manager.entries()[0].term == "hello, world")
    }

    @Test("importCSV falls back to custom for unknown category")
    func importCSVUnknownCategory() {
        let manager = makeManager()
        let csv = """
        Word,Category
        Test,UnknownCategory
        """
        let count = manager.importCSV(csv)
        #expect(count == 1)
        #expect(manager.entries()[0].category == .custom)
    }

    @Test("importCSV skips empty terms")
    func importCSVSkipsEmptyTerms() {
        let manager = makeManager()
        let csv = """
        Word,Category
        ,Person
        Valid,Person
        """
        let count = manager.importCSV(csv)
        #expect(count == 1)
        #expect(manager.entries()[0].term == "Valid")
    }

    @Test("importCSV is case-insensitive for category")
    func importCSVCaseInsensitive() {
        let manager = makeManager()
        let csv = """
        Word,Category
        Test,technical
        """
        let count = manager.importCSV(csv)
        #expect(count == 1)
        #expect(manager.entries()[0].category == .technical)
    }

    // MARK: - CSV Roundtrip

    @Test("Export then import roundtrip preserves entries")
    func csvRoundtrip() {
        let writer = makeManager()
        writer.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        writer.addEntry(VocabularyEntry(term: "Balvinder", category: .person))
        writer.addEntry(VocabularyEntry(term: "SAAS", category: .acronym))

        let csv = writer.exportCSV()

        let reader = makeManager()
        let count = reader.importCSV(csv)
        #expect(count == 3)

        let entries = reader.entries()
        #expect(entries.map(\.term).sorted() == ["Balvinder", "MarkLogic", "SAAS"])
    }

    // MARK: - Migration

    @Test("Legacy flat words migrate to custom entries on init")
    func legacyMigration() {
        let suite = "com.susurrus.vocab.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["word1", "word2"], forKey: "vocabularyWords")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Public init with defaults that has legacy flat words — will migrate and seed
        let manager = VocabularyManager(defaults: defaults)
        let entries = manager.entries()
        // Migration converts flat words + seeds defaults, so we get at least 2 migrated words
        #expect(entries.contains(where: { $0.term == "word1" }))
        #expect(entries.contains(where: { $0.term == "word2" }))
        // Legacy key should be removed
        #expect(defaults.stringArray(forKey: "vocabularyWords") == nil)
    }

    @Test("Migration does not re-run when entries already exist")
    func migrationRunsOnce() {
        let suite = "com.susurrus.vocab.migrate.once.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Pre-populate with legacy data
        defaults.set(["alpha"], forKey: "vocabularyWords")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // First init migrates
        let first = VocabularyManager(defaults: defaults)
        let firstCount = first.entries().count

        // Second init should not duplicate (entriesKey already set)
        let second = VocabularyManager(defaults: defaults)
        #expect(second.entries().count == firstCount)
    }

    // MARK: - Deduplication

    @Test("addEntry rejects case-insensitive duplicates")
    func addEntryDeduplicates() {
        let manager = makeManager()
        #expect(manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical)))
        #expect(!manager.addEntry(VocabularyEntry(term: "marklogic", category: .custom)))
        #expect(manager.entries().count == 1)
        // Original casing and category are kept.
        #expect(manager.entries()[0].term == "MarkLogic")
        #expect(manager.entries()[0].category == .technical)
    }

    @Test("importCSV counts only newly added entries")
    func importCSVSkipsDuplicates() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        let count = manager.importCSV("Word,Category\nMarkLogic,Technical\nCoRB,Technical")
        #expect(count == 1)
        #expect(manager.entries().count == 2)
    }

    // MARK: - Usage stats

    @Test("recordUsage bumps count for terms present in text")
    func recordUsageBumps() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        manager.addEntry(VocabularyEntry(term: "Susurrus", category: .product))

        manager.recordUsage(in: "we shipped the MarkLogic connector today")

        let entries = manager.entries()
        let ml = entries.first { $0.term == "MarkLogic" }
        let su = entries.first { $0.term == "Susurrus" }
        #expect(ml?.useCount == 1)
        #expect(ml?.lastUsedAt != nil)
        #expect((su?.useCount ?? 0) == 0)
    }

    @Test("recordUsage matches split compound terms")
    func recordUsageMatchesCompound() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        manager.recordUsage(in: "the mark logic cluster")
        #expect(manager.entries().first { $0.term == "MarkLogic" }?.useCount == 1)
    }

    @Test("recordUsage accumulates across calls")
    func recordUsageAccumulates() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "SPARQL", category: .acronym))
        manager.recordUsage(in: "run the SPARQL query")
        manager.recordUsage(in: "another SPARQL query")
        #expect(manager.entries().first { $0.term == "SPARQL" }?.useCount == 2)
    }

    @Test("Concurrent recordUsage and addEntry don't lose updates")
    func concurrentWritesNoLostUpdates() async {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))

        // Hammer recordUsage (background) and addEntry (main-like) in
        // parallel; with serialization, all added entries survive and the
        // usage counter reflects every recordUsage call.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { manager.recordUsage(in: "using MarkLogic now") }
                group.addTask { manager.addEntry(VocabularyEntry(term: "Term\(i)", category: .custom)) }
            }
        }

        let entries = manager.entries()
        // 1 seed + 50 added terms, none lost.
        #expect(entries.count == 51)
        // Every recordUsage bumped the counter.
        #expect(entries.first { $0.term == "MarkLogic" }?.useCount == 50)
    }

    // MARK: - Relevance-filtered LLM context

    @Test("llmContextString(relevantTo:) includes only evidenced terms")
    func relevantContextFiltersUnspoken() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        manager.addEntry(VocabularyEntry(term: "Schengen", category: .place))

        let context = manager.llmContextString(relevantTo: "migrating the mark logic cluster")
        #expect(context.contains("MarkLogic"))
        #expect(!context.contains("Schengen"))
    }

    @Test("llmContextString(relevantTo:) includes fuzzy-evidenced terms")
    func relevantContextIncludesFuzzy() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "SPARQL", category: .technical))
        let context = manager.llmContextString(relevantTo: "run the sparkle query")
        #expect(context.contains("SPARQL"))
    }

    @Test("llmContextString(relevantTo:) is empty when nothing matches")
    func relevantContextEmptyWhenNoMatch() {
        let manager = makeManager()
        manager.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        #expect(manager.llmContextString(relevantTo: "the weather is nice today").isEmpty)
    }
}
