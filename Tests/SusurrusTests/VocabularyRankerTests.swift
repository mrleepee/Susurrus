import Foundation
import Testing
@testable import SusurrusKit

@Suite("VocabularyRanker Tests")
struct VocabularyRankerTests {

    private let ranker = VocabularyRanker()

    private func entries(_ terms: [(String, VocabularyCategory)]) -> [VocabularyEntry] {
        terms.map { VocabularyEntry(term: $0.0, category: $0.1) }
    }

    @Test("Terms evidenced in preview rank first")
    func evidencedFirst() {
        let vocab = entries([
            ("Balvinder", .person),
            ("MarkLogic", .technical),
            ("Susurrus", .product),
        ])
        let terms = ranker.selectTerms(
            previewText: "we migrated the mark logic cluster yesterday",
            vocabulary: vocab
        )
        #expect(terms.first == "MarkLogic")
    }

    @Test("Phonetic preview hit counts as evidence: sparkle → SPARQL")
    func phoneticEvidence() {
        let vocab = entries([
            ("Balvinder", .person),
            ("SPARQL", .technical),
        ])
        let terms = ranker.selectTerms(
            previewText: "run the sparkle query",
            vocabulary: vocab
        )
        #expect(terms.first == "SPARQL")
    }

    @Test("Notebook terms rank above unevidenced vocabulary")
    func notebookAboveEvergreen() {
        let vocab = entries([("Balvinder", .person)])
        let terms = ranker.selectTerms(
            previewText: "",
            vocabulary: vocab,
            notebookTerms: ["BioFinder"]
        )
        #expect(terms == ["BioFinder", "Balvinder"])
    }

    @Test("All vocabulary is returned when nothing is evidenced")
    func evergreenFill() {
        let vocab = entries([
            ("Schengen", .place),
            ("Susurrus", .product),
            ("Elaine", .person),
        ])
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab)
        #expect(terms.count == 3)
        // Category priority: product before person before place.
        #expect(terms == ["Susurrus", "Elaine", "Schengen"])
    }

    @Test("Duplicates across tiers are removed case-insensitively")
    func deduplicates() {
        let vocab = entries([("MarkLogic", .technical)])
        let terms = ranker.selectTerms(
            previewText: "the marklogic upgrade",
            vocabulary: vocab,
            notebookTerms: ["marklogic", "CoRB"]
        )
        #expect(terms == ["MarkLogic", "CoRB"])
    }

    @Test("Acronym entries surface uppercased")
    func acronymsUppercased() {
        let vocab = [VocabularyEntry(term: "qas", category: .acronym)]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab)
        #expect(terms == ["QAS"])
    }
}
