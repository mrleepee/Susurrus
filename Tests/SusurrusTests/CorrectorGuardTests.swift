import Foundation
import Testing
@testable import SusurrusKit

@Suite("CorrectorGuard Tests")
struct CorrectorGuardTests {

    private let corrector = TranscriptCorrector()

    private let vocabulary: [VocabularyEntry] = [
        VocabularyEntry(term: "XQuery", category: .custom),
        VocabularyEntry(term: "SAAS", category: .acronym),
        VocabularyEntry(term: "Harnadh", category: .person),
    ]

    private func correct(_ text: String) -> String {
        corrector.correct(text, vocabulary: vocabulary, rules: []).text
    }

    // MARK: - Guard 1: inflected common words

    @Test("Inflected common verb is not fuzzy-corrected: says stays says")
    func inflectedCommonWordKept() {
        #expect(correct("Our QA team says the SAAS dashboard is fine")
            == "Our QA team says the SAAS dashboard is fine")
    }

    @Test("Inflections count as common for the fuzzy pass only")
    func commonWordsInflections() {
        for word in ["says", "saying", "asked", "tries", "goes"] {
            #expect(CommonWords.containsOrInflection(word))
        }
        // Not in the frequency list itself, so only the fuzzy pass sees them.
        for word in ["says", "tries", "goes"] {
            #expect(!CommonWords.contains(word))
        }
        #expect(!CommonWords.containsOrInflection("xquery"))
    }

    @Test("Exact recasing of an inflected-looking term still works: ids → IDs")
    func exactRecasingUnaffected() {
        let vocab = vocabulary + [VocabularyEntry(term: "IDs", category: .custom)]
        #expect(corrector.correct("the ids are wrong", vocabulary: vocab, rules: []).text == "the IDs are wrong")
    }

    // MARK: - Guard 2: compound head nouns

    @Test("Acronym modifier blocks fuzzy match on the head noun")
    func acronymModifierBlocksFuzzy() {
        #expect(correct("The CTS query returns documents")
            == "The CTS query returns documents")
    }

    @Test("Capitalised non-initial modifier blocks fuzzy match on the head noun")
    func capitalisedModifierBlocksFuzzy() {
        #expect(correct("and the Cypher query for the graph")
            == "and the Cypher query for the graph")
    }

    @Test("Lowercase preceding word still allows the fuzzy fix")
    func lowercaseContextStillFixed() {
        #expect(correct("he wrote the query retry logic")
            == "he wrote the XQuery retry logic")
    }

    @Test("Sentence-initial word with no modifier keeps current behaviour")
    func sentenceInitialUnchanged() {
        #expect(correct("Query results come back")
            == "XQuery results come back")
    }

    // MARK: - Misheard names still fixed

    @Test("Misheard name is still fixed by fuzzy match")
    func misheardNameFixed() {
        #expect(correct("ask Harned about it") == "ask Harnadh about it")
    }
}
