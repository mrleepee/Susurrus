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

    @Test("History context terms rank above unevidenced vocabulary")
    func contextAboveEvergreen() {
        let vocab = entries([("Balvinder", .person)])
        let terms = ranker.selectTerms(
            previewText: "",
            vocabulary: vocab,
            contextTerms: ["BioFinder"]
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
            contextTerms: ["marklogic", "CoRB"]
        )
        #expect(terms == ["MarkLogic", "CoRB"])
    }

    @Test("Acronym entries surface uppercased")
    func acronymsUppercased() {
        let vocab = [VocabularyEntry(term: "qas", category: .acronym)]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab)
        #expect(terms == ["QAS"])
    }

    // MARK: - Grace tier for newly learned terms

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 24 * 60 * 60) }

    @Test("A just-learned term outranks an established heavily-used one")
    func newTermBeatsEvergreen() {
        // The production failure this fixes: "Posthog" reached the prompt 0
        // times while "MarkLogic" held a slot on 193 of 260 stops.
        let vocab = [
            VocabularyEntry(term: "MarkLogic", category: .technical, useCount: 24),
            VocabularyEntry(term: "Posthog", category: .custom, useCount: 1, createdAt: daysAgo(1)),
        ]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab, now: now)
        #expect(terms == ["Posthog", "MarkLogic"])
    }

    @Test("Legacy entries with no createdAt are treated as established")
    func nilCreatedAtIsNotNew() {
        let vocab = [
            VocabularyEntry(term: "MarkLogic", category: .technical, useCount: 24),
            VocabularyEntry(term: "Brinda", category: .person, useCount: 0),
        ]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab, now: now)
        #expect(terms == ["MarkLogic", "Brinda"])
    }

    @Test("A term graduates out of the grace tier once it has been used enough")
    func graduatesOnUse() {
        let vocab = [
            VocabularyEntry(term: "MarkLogic", category: .technical, useCount: 24),
            VocabularyEntry(term: "Posthog", category: .custom,
                            useCount: VocabularyRanker.graceUseThreshold, createdAt: daysAgo(1)),
        ]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab, now: now)
        #expect(terms == ["MarkLogic", "Posthog"])
    }

    @Test("A term ages out of the grace tier")
    func agesOut() {
        let vocab = [
            VocabularyEntry(term: "MarkLogic", category: .technical, useCount: 24),
            VocabularyEntry(term: "Posthog", category: .custom, useCount: 1, createdAt: daysAgo(15)),
        ]
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab, now: now)
        #expect(terms == ["MarkLogic", "Posthog"])
    }

    @Test("Grace tier is capped so a bulk import can't fill the budget")
    func graceIsCapped() {
        var vocab = (1...8).map {
            VocabularyEntry(term: "New\($0)", category: .custom, createdAt: daysAgo(Double(9 - $0)))
        }
        vocab.append(VocabularyEntry(term: "MarkLogic", category: .technical, useCount: 24))
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab, now: now)
        // Newest first, capped, then the evergreen tier resumes.
        #expect(Array(terms.prefix(6)) == ["New8", "New7", "New6", "New5", "New4", "MarkLogic"])
        #expect(terms.count == 9)
    }

    @Test("Grace tier never displaces preview evidence or history context")
    func graceRanksBelowTiersOneAndTwo() {
        let vocab = [
            VocabularyEntry(term: "SPARQL", category: .technical),
            VocabularyEntry(term: "Posthog", category: .custom, createdAt: daysAgo(1)),
        ]
        let terms = ranker.selectTerms(
            previewText: "run the sparkle query",
            vocabulary: vocab,
            contextTerms: ["BioFinder"],
            now: now
        )
        #expect(terms == ["SPARQL", "BioFinder", "Posthog"])
    }
}

// MARK: - Tier 2 cap

@Suite("VocabularyRanker tier-2 cap Tests")
struct VocabularyRankerContextCapTests {

    private let ranker = VocabularyRanker()

    private func vocab(_ n: Int) -> [VocabularyEntry] {
        (1...n).map { VocabularyEntry(term: "Vocab\($0)", category: .custom, useCount: 10 - $0) }
    }

    @Test("Recent context cannot take more than its share of the budget")
    func contextIsCapped() {
        // The production failure: recentBiasTerms returns up to 20 terms into a
        // ~15-slot budget, so on a name-dense day tier 2 took everything and the
        // user's own curated vocabulary never reached the prompt. Measured
        // 2026-08-18: curated share fell 66% -> 33%.
        let context = (1...20).map { "Context\($0)" }
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab(10), contextTerms: context)
        let fromContext = terms.filter { $0.hasPrefix("Context") }
        #expect(fromContext.count == VocabularyRanker.maxContextTerms)
        #expect(terms.prefix(VocabularyRanker.maxContextTerms).allSatisfy { $0.hasPrefix("Context") })
    }

    @Test("Curated vocabulary still reaches the prompt when context is abundant")
    func vocabularySurvivesAbundantContext() {
        let context = (1...20).map { "Context\($0)" }
        let terms = ranker.selectTerms(previewText: "", vocabulary: vocab(10), contextTerms: context)
        #expect(terms.contains("Vocab1"))
        #expect(terms.filter { $0.hasPrefix("Vocab") }.count == 10)
    }

    @Test("The cap keeps the best-evidenced context terms, which arrive first")
    func capKeepsTheTop() {
        // extractBiasTerms hands them over ranked by how many dictations
        // contain them, so taking the prefix keeps the most-repeated.
        let context = (1...20).map { "Context\($0)" }
        let terms = ranker.selectTerms(previewText: "", vocabulary: [], contextTerms: context)
        #expect(terms == (1...VocabularyRanker.maxContextTerms).map { "Context\($0)" })
    }

    @Test("Context below the cap is passed through untouched")
    func shortContextUnaffected() {
        let terms = ranker.selectTerms(
            previewText: "", vocabulary: vocab(3), contextTerms: ["Alpha", "Bravo"])
        #expect(terms.prefix(2) == ["Alpha", "Bravo"])
    }

    @Test("The cap does not disturb the grace tier")
    func graceTierUnaffected() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var v = vocab(5)
        v.append(VocabularyEntry(term: "JustLearned", category: .custom,
                                 useCount: 0, createdAt: now.addingTimeInterval(-3600)))
        let terms = ranker.selectTerms(
            previewText: "", vocabulary: v,
            contextTerms: (1...20).map { "Context\($0)" }, now: now)
        let grace = terms.firstIndex(of: "JustLearned")!
        let firstEvergreen = terms.firstIndex(of: "Vocab1")!
        #expect(grace < firstEvergreen)
        #expect(grace == VocabularyRanker.maxContextTerms)
    }

    @Test("Preview evidence still outranks capped context")
    func previewStillWins() {
        let v = [VocabularyEntry(term: "SPARQL", category: .technical)]
        let terms = ranker.selectTerms(
            previewText: "run the sparkle query", vocabulary: v,
            contextTerms: (1...20).map { "Context\($0)" })
        #expect(terms.first == "SPARQL")
    }
}
