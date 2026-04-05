import Testing
@testable import SusurrusKit

@Suite("Vocabulary Tests")
struct VocabularyTests {

    private func makeManager() -> VocabularyManager {
        VocabularyManager.createForTesting()
    }

    @Test("Empty vocabulary by default")
    func emptyByDefault() {
        let manager = makeManager()
        #expect(manager.vocabularyWords().isEmpty)
        #expect(manager.entries().isEmpty)
    }

    @Test("Set and get vocabulary words")
    func setAndGetWords() {
        let manager = makeManager()
        manager.setVocabularyWords(["algorithm", "API", "recursion"])
        #expect(manager.vocabularyWords() == ["algorithm", "API", "recursion"])
    }

    @Test("Prompt string joins with comma and space")
    func promptString() {
        let manager = makeManager()
        manager.setVocabularyWords(["Swift", "Objective-C"])
        #expect(manager.promptString() == "Swift, Objective-C")
    }

    @Test("Empty vocabulary gives empty prompt")
    func emptyPrompt() {
        let manager = makeManager()
        #expect(manager.promptString() == "")
    }

    @Test("Single word has no separator")
    func singleWord() {
        let manager = makeManager()
        manager.setVocabularyWords(["Kubernetes"])
        #expect(manager.promptString() == "Kubernetes")
    }

    @Test("Overwrite replaces previous words")
    func overwriteWords() {
        let manager = makeManager()
        manager.setVocabularyWords(["old"])
        manager.setVocabularyWords(["new"])
        #expect(manager.vocabularyWords() == ["new"])
    }

    @Test("VocabularyError equality")
    func errorEquality() {
        #expect(VocabularyError.wordTooLong("a") == VocabularyError.wordTooLong("a"))
        #expect(VocabularyError.tooManyWords(1) == VocabularyError.tooManyWords(1))
        #expect(VocabularyError.tooManyWords(1) != VocabularyError.tooManyWords(2))
    }

    // MARK: - F9: Categorized entries

    @Test("Add entry with category")
    func addEntry() {
        let manager = makeManager()
        let entry = VocabularyEntry(term: "DataBid", category: .product)
        manager.addEntry(entry)
        let all = manager.entries()
        #expect(all.count == 1)
        #expect(all[0].term == "DataBid")
        #expect(all[0].category == .product)
    }

    @Test("Remove entry by ID")
    func removeEntry() {
        let manager = makeManager()
        let e1 = VocabularyEntry(term: "Keep", category: .person)
        let e2 = VocabularyEntry(term: "Remove", category: .custom)
        manager.addEntry(e1)
        manager.addEntry(e2)
        manager.removeEntry(id: e2.id)
        let remaining = manager.entries()
        #expect(remaining.count == 1)
        #expect(remaining[0].term == "Keep")
    }

    @Test("Set entries replaces all")
    func setEntries() {
        let manager = makeManager()
        manager.setEntries([
            VocabularyEntry(term: "A", category: .person),
            VocabularyEntry(term: "B", category: .place),
        ])
        #expect(manager.entries().count == 2)
    }

    @Test("Prompt string flattens entries")
    func promptStringFlattensEntries() {
        let manager = makeManager()
        manager.setEntries([
            VocabularyEntry(term: "DataBid", category: .product),
            VocabularyEntry(term: "K8s", category: .technical),
        ])
        #expect(manager.promptString() == "DataBid, K8s")
    }

    @Test("LLM context string with categories")
    func llmContextString() {
        let manager = makeManager()
        manager.setEntries([
            VocabularyEntry(term: "DataBid", category: .product),
            VocabularyEntry(term: "Jane", category: .person),
        ])
        let context = manager.llmContextString()
        #expect(context.contains("\"DataBid\" is a product name — always capitalize, never translate"))
        #expect(context.contains("\"Jane\" is a person's name — always capitalize"))
    }

    @Test("Empty vocabulary gives empty LLM context")
    func emptyLLMContext() {
        let manager = makeManager()
        #expect(manager.llmContextString() == "")
    }

    @Test("Flat words migration to custom entries")
    func migrationFromFlatWords() {
        // Use the factory to get an isolated manager, then write flat words directly
        let manager = VocabularyManager.createForTesting()
        // Set flat words using the legacy API (this triggers migration internally)
        manager.setVocabularyWords(["Word1", "Word2"])
        // Now verify entries have custom category
        let entries = manager.entries()
        #expect(entries.count == 2)
        #expect(entries[0].term == "Word1")
        #expect(entries[0].category == VocabularyCategory.custom)
        #expect(entries[1].term == "Word2")
        #expect(entries[1].category == VocabularyCategory.custom)
        // promptString should still work the same
        #expect(manager.promptString() == "Word1, Word2")
    }

    @Test("Entry round-trip encode/decode")
    func entryRoundTrip() {
        let entry = VocabularyEntry(term: "Test", category: .acronym)
        let manager = makeManager()
        manager.setEntries([entry])
        let loaded = manager.entries()
        #expect(loaded.count == 1)
        #expect(loaded[0].term == entry.term)
        #expect(loaded[0].category == entry.category)
    }
}
