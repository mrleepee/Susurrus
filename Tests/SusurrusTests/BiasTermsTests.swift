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

    @Test("Shouted sentences do not contribute ALLCAPS words as bias terms")
    func shoutedSentencesExcluded() {
        // Whisper artifact seen in production: whole passage in capitals.
        let terms = ProperNoun.extractBiasTerms(
            from: ["FAILING THE STATUTORY RESIDENCY TEST TODAY. The QAS pipeline is fine."],
            limit: 20
        )
        #expect(!terms.contains("STATUTORY"))
        #expect(!terms.contains("TEST"))
        #expect(!terms.contains("THE"))
        // A legit acronym in a normally-cased sentence survives.
        #expect(terms.contains("QAS"))
    }

    @Test("ALLCAPS common word in a normal sentence is not a bias term")
    func allCapsCommonWordExcluded() {
        let terms = ProperNoun.extractBiasTerms(
            from: ["We shipped THE update with SPARQL support."],
            limit: 20
        )
        #expect(!terms.contains("THE"))
        #expect(terms.contains("SPARQL"))
    }

    @Test("Acronym-dense but short technical phrasing keeps its acronyms")
    func acronymDenseKept() {
        // 2 of 5 eligible words are ALLCAPS — under the shouting threshold.
        let terms = ProperNoun.extractBiasTerms(
            from: ["The QAS and CAS pipelines are stable."],
            limit: 20
        )
        #expect(terms.contains("QAS"))
        #expect(terms.contains("CAS"))
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

// MARK: - Ordinary-word exclusion (SPEC-prompt-bias-composition phase 1)

@Suite("Bias terms exclude ordinary words the user writes lowercase")
struct BiasTermOrdinaryWordTests {

    /// Stand-in for the system word list so these tests don't depend on
    /// /usr/share/dict/words being present or on its exact contents.
    private let dictionary = EnglishDictionary(words: [
        "document", "pipeline", "supplier", "julia", "paul", "rajesh", "frontier",
    ])

    /// History in which the user writes `word` in lowercase mid-sentence.
    private func corpus(_ word: String, times: Int) -> [String] {
        (1...times).map { _ in "we reviewed the \(word) again yesterday" }
    }

    private func terms(
        from texts: [String],
        casingCorpus: [String],
        dictionary: EnglishDictionary
    ) -> [String] {
        // Exercises the shipped rule rather than restating it — an earlier
        // version of this helper duplicated the predicate and drifted from it.
        return ProperNoun.extractBiasTerms(
            from: texts,
            limit: 20,
            excluding: ProperNoun.ordinaryWordExclusion(
                profile: CasingProfile.build(from: casingCorpus),
                dictionary: dictionary
            )
        )
    }

    @Test("A dictionary word the user writes lowercase is not a bias term")
    func rejectsOrdinaryWord() {
        let out = terms(
            from: ["I attached the Document to the ticket."],
            casingCorpus: corpus("document", times: 3),
            dictionary: dictionary
        )
        #expect(!out.contains("Document"))
    }

    @Test("A dictionary word the user never writes lowercase survives")
    func keepsNameThatIsAlsoADictionaryWord() {
        // The reason the dictionary can't be trusted alone: macOS ships web2,
        // which contains given names. Only the casing evidence separates them.
        // Both mid-sentence: a sentence-initial capital is skipped for its own
        // reasons and would not exercise this rule.
        let out = terms(
            from: ["Yesterday Julia and Paul reviewed it."],
            casingCorpus: ["I asked Julia about it.", "I asked Paul about it."],
            dictionary: dictionary
        )
        #expect(out.contains("Julia"))
        #expect(out.contains("Paul"))
    }

    @Test("A word absent from the dictionary survives whatever its casing record")
    func dictionaryGateShortCircuits() {
        // Even with overwhelming lowercase evidence, a non-dictionary word is
        // never rejected — condition 1 fails, so the rule cannot fire.
        let out = terms(
            from: ["Spoke to Kalpesh today."],
            casingCorpus: corpus("kalpesh", times: 9),
            dictionary: dictionary
        )
        #expect(out.contains("Kalpesh"))
    }

    @Test("A word with no casing record at all survives")
    func noEvidenceMeansNoRejection() {
        let out = terms(
            from: ["The Supplier record is wrong."],
            casingCorpus: ["Unrelated history with nothing in common."],
            dictionary: dictionary
        )
        #expect(out.contains("Supplier"))
    }

    @Test("Mixed usage below the 50% bar survives")
    func mixedUsageSurvives() {
        // Written lowercase twice, capitalized three times: under half, so the
        // capital is plausibly deliberate and the term stays eligible.
        let out = terms(
            from: ["The Pipeline broke."],
            casingCorpus: [
                "we ran the pipeline twice",
                "we ran the pipeline again",
                "the Pipeline team met",
                "the Pipeline team met again",
                "the Pipeline team met once more",
            ],
            dictionary: dictionary
        )
        #expect(out.contains("Pipeline"))
    }

    @Test("ALL-CAPS acronyms are exempt even with lowercase evidence against them")
    func acronymsUnaffected() {
        // web2 contains "dom", "stem", "uri" and "mrs". Without the ALL-CAPS
        // exemption, writing "stem" once in prose would drop STEM from the
        // prompt — the acronym and the noun are not the same word.
        let out = terms(
            from: ["The STEM queue is full."],
            casingCorpus: corpus("stem", times: 9),
            dictionary: EnglishDictionary(words: ["stem"])
        )
        #expect(out.contains("STEM"))
    }

    @Test("Extraction is deterministic across runs")
    func deterministic() {
        let texts = ["Rajesh and Julia reviewed the Document and the Supplier record."]
        let casing = corpus("document", times: 3)
        let a = terms(from: texts, casingCorpus: casing, dictionary: dictionary)
        let b = terms(from: texts, casingCorpus: casing, dictionary: dictionary)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test("Default extraction still admits everything")
    func defaultIsUnchanged() {
        let out = ProperNoun.extractBiasTerms(
            from: ["I attached the Document to the ticket."],
            limit: 20
        )
        #expect(out.contains("Document"))
    }

    @Test("A missing system dictionary disables the filter rather than emptying it")
    func missingDictionaryIsSafe() {
        let empty = EnglishDictionary(words: [])
        #expect(!empty.isAvailable)
        let out = terms(
            from: ["I attached the Document to the ticket."],
            casingCorpus: corpus("document", times: 9),
            dictionary: empty
        )
        #expect(out.contains("Document"))
    }
}

@Suite("CasingProfile.writesInLowercase Tests")
struct CasingProfileLowercaseEvidenceTests {

    @Test("One lowercase sighting answers the bias question but not the edit question")
    func oneSightingSuffices() {
        // The two thresholds must stay independent: one sighting is enough to
        // keep a word out of the prompt, and deliberately not enough to propose
        // rewriting the user's text.
        let profile = CasingProfile.build(from: ["we reviewed the document yesterday"])
        #expect(profile.writesInLowercase("Document"))
        #expect(profile.suggestions(for: "the Document is here", vocabulary: []).isEmpty)
    }

    @Test("An unseen word returns false")
    func unseenIsFalse() {
        let profile = CasingProfile.build(from: ["nothing relevant here"])
        #expect(!profile.writesInLowercase("Document"))
    }

    @Test("Exactly half lowercase clears the bar")
    func halfClearsTheBar() {
        let profile = CasingProfile.build(from: [
            "we ran the pipeline once", "the Pipeline team met",
        ])
        #expect(profile.writesInLowercase("Pipeline"))
    }

    @Test("Mostly capitalized returns false")
    func mostlyCapitalizedIsFalse() {
        let profile = CasingProfile.build(from: [
            "we ran the pipeline once",
            "the Pipeline team met", "the Pipeline team met again",
        ])
        #expect(!profile.writesInLowercase("Pipeline"))
    }

    @Test("Sentence-initial capitals are not counted as evidence either way")
    func sentenceInitialIgnored() {
        // "Document" starting a sentence says nothing — build() only counts
        // mid-phrase tokens, so this corpus carries no evidence at all.
        let profile = CasingProfile.build(from: ["Document the change. Document it again."])
        #expect(!profile.writesInLowercase("Document"))
    }
}

// MARK: - Repetition ranking (SPEC-prompt-bias-composition phase 2)

@Suite("Bias terms rank by how many dictations contain them")
struct BiasTermRepetitionTests {

    @Test("A term in several dictations outranks one said once")
    func repeatedBeatsOneOff() {
        // The production failure this fixes: 'Iceberg' and 'IDs' appeared in
        // zero of the last 30 dictations, held prompt slots anyway, and Whisper
        // inserted both into a dictation where neither was spoken.
        let terms = ProperNoun.extractBiasTerms(
            from: [
                "A one-off mention of Iceberg here.",
                "We deployed MarkLogic again.",
                "The MarkLogic cluster is fine.",
                "Checking MarkLogic once more.",
            ],
            limit: 20
        )
        #expect(terms.first == "MarkLogic")
        #expect(terms.contains("Iceberg"))          // demoted, not banned
        #expect(terms.firstIndex(of: "MarkLogic")! < terms.firstIndex(of: "Iceberg")!)
    }

    @Test("Repetition inside a single dictation counts once")
    func withinTextCountsOnce() {
        // Otherwise one rambling dictation could crown any term it repeated.
        let terms = ProperNoun.extractBiasTerms(
            from: [
                "We saw Starrocks and Starrocks and Starrocks again.",
                "We discussed Kalpesh today.",
                "Then Kalpesh replied already.",
            ],
            limit: 20
        )
        #expect(terms.first == "Kalpesh")
    }

    @Test("Equal repetition falls back to first appearance")
    func tiesBreakOnFirstAppearance() {
        let texts = ["Spoke to Kalpesh and Subha.", "Saw Kalpesh and Subha again."]
        let terms = ProperNoun.extractBiasTerms(from: texts, limit: 20)
        #expect(terms == ["Kalpesh", "Subha"])
        #expect(ProperNoun.extractBiasTerms(from: texts, limit: 20) == terms)
    }

    @Test("The limit is applied after ranking, not before")
    func limitAppliesAfterRanking() {
        // Previously extraction stopped as soon as `limit` candidates had been
        // seen, so a repeated term appearing late in the window could be cut
        // before its repetition was ever counted.
        let terms = ProperNoun.extractBiasTerms(
            from: [
                "Alpha Bravo Charlie Delta were mentioned once.",
                "Now Zulu appears.",
                "Zulu again here.",
                "And Zulu once more.",
            ],
            limit: 1
        )
        #expect(terms == ["Zulu"])
    }

    @Test("Ranking survives the ordinary-word exclusion")
    func rankingComposesWithExclusion() {
        let dictionary = EnglishDictionary(words: ["document"])
        let profile = CasingProfile.build(from: [
            "we reviewed the document", "we filed the document", "we signed the document",
        ])
        let terms = ProperNoun.extractBiasTerms(
            from: [
                "The Document was late.", "The Document was late again.",
                "The Document once more.", "Then Kalpesh replied.",
            ],
            limit: 20,
            excluding: ProperNoun.ordinaryWordExclusion(profile: profile, dictionary: dictionary)
        )
        // Document is the most repeated term and still must not appear.
        #expect(!terms.contains("Document"))
        #expect(terms == ["Kalpesh"])
    }

    @Test("An empty window yields no terms")
    func emptyWindow() {
        #expect(ProperNoun.extractBiasTerms(from: [], limit: 20).isEmpty)
    }
}
