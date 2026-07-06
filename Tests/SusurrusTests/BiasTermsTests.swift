import Foundation
import Testing
@testable import SusurrusKit

@Suite("ProperNoun bias term extraction Tests")
struct ProperNounBiasTermsTests {

    @Test("Extracts CamelCase, ALLCAPS, and capitalized-uncommon words")
    func extractsProperNouns() {
        let terms = ProperNoun.extractBiasTerms(
            from: ["Talked to Jayendra about the MarkLogic upgrade and the QAS pipeline."],
            limit: 20
        )
        #expect(terms.contains("Jayendra"))
        #expect(terms.contains("MarkLogic"))
        #expect(terms.contains("QAS"))
        #expect(!terms.contains("Talked"))  // sentence-initial
        #expect(!terms.contains("about"))
    }

    @Test("Deduplicates case-insensitively across texts")
    func deduplicates() {
        let terms = ProperNoun.extractBiasTerms(
            from: ["The MarkLogic cluster.", "More MARKLOGIC work today."],
            limit: 20
        )
        #expect(terms.filter { $0.lowercased() == "marklogic" }.count == 1)
    }

    @Test("Respects the term limit")
    func respectsLimit() {
        let text = "We saw Alpha1x, Bravo2x, Charlie3x, Delta4x and Echo5x together."
        let terms = ProperNoun.extractBiasTerms(from: [text], limit: 3)
        #expect(terms.count == 3)
    }

    @Test("Newest text wins ordering")
    func newestFirst() {
        let terms = ProperNoun.extractBiasTerms(
            from: ["The BioFinder demo.", "The Evoca launch."],
            limit: 20
        )
        #expect(terms == ["BioFinder", "Evoca"])
    }
}

@Suite("TranscriptionHistoryManager bias terms Tests")
struct HistoryBiasTermsTests {

    @Test("recentBiasTerms extracts from newest items first")
    func extractsFromHistory() {
        let mgr = TranscriptionHistoryManager.createForTesting()
        mgr.add("Discussed the Evoca rollout yesterday.")
        mgr.add("The MarkLogic migration is on track.")  // newest

        let terms = mgr.recentBiasTerms()
        #expect(terms.first == "MarkLogic")
        #expect(terms.contains("Evoca"))
    }

    @Test("recentBiasTerms respects the item window")
    func respectsItemWindow() {
        let mgr = TranscriptionHistoryManager.createForTesting()
        mgr.add("Old entry about BioFinder.")
        for i in 0..<10 {
            mgr.add("Filler entry number \(i) with nothing special.")
        }
        // BioFinder is the 11th-newest item — outside a 10-item window.
        let terms = mgr.recentBiasTerms(itemLimit: 10)
        #expect(!terms.contains("BioFinder"))
    }

    @Test("recentBiasTerms is empty for empty history")
    func emptyHistory() {
        let mgr = TranscriptionHistoryManager.createForTesting()
        #expect(mgr.recentBiasTerms().isEmpty)
    }
}
