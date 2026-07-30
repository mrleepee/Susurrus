import Foundation
import Testing
@testable import SusurrusKit

@Suite("CasingProfile Tests")
struct CasingProfileTests {

    /// Enough lowercase sightings to clear `minLowercaseSightings`.
    private func corpus(_ word: String, times: Int = 4) -> [String] {
        (1...times).map { _ in "we reviewed the \(word) again yesterday" }
    }

    private func suggestions(
        for text: String,
        corpus texts: [String],
        vocabulary: [VocabularyEntry] = []
    ) -> [CasingSuggestion] {
        CasingProfile.build(from: texts).suggestions(for: text, vocabulary: vocabulary)
    }

    // MARK: - Firing

    @Test("Flags a mid-phrase capital the user normally writes lowercase")
    func flagsMidPhraseCapital() {
        let hits = suggestions(for: "remove New Documents from test", corpus: corpus("documents"))
        #expect(hits.map(\.original) == ["Documents"])
        #expect(hits.map(\.suggested) == ["documents"])
    }

    @Test("Applying a suggestion rewrites only that occurrence")
    func applyRewritesOneOccurrence() {
        let text = "documents and Documents"
        let hits = suggestions(for: text, corpus: corpus("documents"))
        #expect(hits.count == 1)
        #expect(CasingProfile.apply(hits, to: text) == "documents and documents")
    }

    @Test("Several flags in one transcript all apply cleanly")
    func multipleSuggestions() {
        let texts = corpus("project") + corpus("text")
        let text = "my voice Text and Project notes"
        let hits = suggestions(for: text, corpus: texts)
        #expect(Set(hits.map(\.original)) == ["Text", "Project"])
        #expect(CasingProfile.apply(hits, to: text) == "my voice text and project notes")
    }

    // MARK: - Not firing

    @Test("Sentence-initial capitals are never flagged")
    func ignoresSentenceInitial() {
        let hits = suggestions(for: "We shipped it. Documents are ready.", corpus: corpus("documents"))
        #expect(hits.isEmpty)
    }

    @Test("A capital after punctuation is left alone — quoted speech and label lists")
    func ignoresAfterPunctuation() {
        // "I said to him, Can you…" and "we have Insert, Cancel, Add" were the
        // measured false positives that this rule removes.
        let hits = suggestions(for: "the buttons are insert, Documents and more", corpus: corpus("documents"))
        #expect(hits.isEmpty)
    }

    @Test("A run of capitals separated by commas is a label list, not prose")
    func ignoresLabelList() {
        let texts = corpus("documents") + corpus("results")
        // Same word, same evidence — only the label-list shape differs.
        #expect(suggestions(for: "we have the Documents and more", corpus: texts)
            .map(\.original) == ["Documents"])
        // "Documents, Results" is the "Insert, Cancel, Add, Copy" shape: the
        // first item is suppressed by the list guard, the second by the
        // after-punctuation guard.
        #expect(suggestions(for: "we have the Documents, Results and more", corpus: texts).isEmpty)
    }

    @Test("Vocabulary always wins — an explicit term is never downcased")
    func vocabularyWins() {
        let hits = suggestions(
            for: "the new Documents pipeline",
            corpus: corpus("documents"),
            vocabulary: [VocabularyEntry(term: "Documents", category: .product)]
        )
        #expect(hits.isEmpty)
    }

    @Test("ALL-CAPS is an acronym, not Title Case")
    func ignoresAllCaps() {
        let hits = suggestions(for: "the new FACET integration", corpus: corpus("facet"))
        #expect(hits.isEmpty)
    }

    @Test("\"I\" is never flagged")
    func ignoresPronounI() {
        let hits = suggestions(for: "yesterday I reviewed it", corpus: corpus("i"))
        #expect(hits.isEmpty)
    }

    @Test("A word with too little evidence is left alone")
    func requiresEnoughEvidence() {
        let thin = Array(corpus("documents").prefix(CasingProfile.minLowercaseSightings - 1))
        #expect(suggestions(for: "remove the Documents now", corpus: thin).isEmpty)
    }

    @Test("A word the user does capitalize mid-phrase is left alone")
    func respectsMixedUsage() {
        // Below minLowercaseRatio: capitalized often enough to be a real name.
        let texts = corpus("datavid", times: 3) + ["we joined Datavid last year", "the Datavid team", "at Datavid today"]
        #expect(suggestions(for: "the Datavid rollout", corpus: texts).isEmpty)
    }

    @Test("An unseen word produces no suggestion")
    func unseenWord() {
        #expect(suggestions(for: "the Wrangler job", corpus: corpus("documents")).isEmpty)
    }

    // MARK: - Applying safely

    @Test("A stale suggestion is discarded rather than corrupting edited text")
    func staleSuggestionIsIgnored() {
        let text = "remove New Documents from test"
        let hits = suggestions(for: text, corpus: corpus("documents"))
        // The user rewrote that span by hand before clicking the chip.
        let edited = "remove New Files from test"
        #expect(CasingProfile.apply(hits, to: edited) == edited)
    }

    @Test("An empty profile suggests nothing")
    func emptyProfile() {
        #expect(CasingProfile().suggestions(for: "the Documents are here", vocabulary: []).isEmpty)
    }
}
