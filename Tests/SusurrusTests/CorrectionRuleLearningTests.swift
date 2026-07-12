import Foundation
import Testing
@testable import SusurrusKit

@Suite("Correction rule learning Tests")
struct CorrectionRuleLearningTests {

    private func makeManagers() -> (CorrectionLearningManager, VocabularyManager) {
        let vocab = VocabularyManager.createForTesting()
        let mgr = CorrectionLearningManager(
            vocabularyManager: vocab,
            defaults: UserDefaults(suiteName: "com.susurrus.rulelearn.test.\(UUID().uuidString)")!
        )
        return (mgr, vocab)
    }

    // MARK: - Promotion guards (from production data, 2026-07-12)

    @Test("Sentence-case churn does not promote lowercase common words")
    func caseChurnNotPromoted() {
        let (mgr, vocab) = makeManagers()
        // User restructured the sentence; "Voice" became mid-sentence "voice".
        mgr.recordCorrection(
            raw: "Voice dictation is the goal",
            edited: "The goal is voice dictation"
        )
        #expect(!vocab.entries().contains { $0.term.lowercased() == "voice" })
        #expect(vocab.entries().isEmpty)
    }

    @Test("Text-initial capitalization flip alone is not promoted")
    func sentenceInitialCapitalizationNotPromoted() {
        let (mgr, vocab) = makeManagers()
        // Same words, only the leading word's case changed — convention,
        // not evidence of a proper noun.
        mgr.recordCorrection(
            raw: "delta shipped yesterday",
            edited: "Delta shipped yesterday"
        )
        #expect(!vocab.entries().contains { $0.term.lowercased() == "delta" })
    }

    @Test("CamelCase promotes even at text start")
    func camelCasePromotesAtStart() {
        let (mgr, vocab) = makeManagers()
        mgr.recordCorrection(raw: "databid is great", edited: "DataBid is great")
        #expect(vocab.entries().contains { $0.term == "DataBid" })
    }

    @Test("Fuzzy near-duplicate of existing vocab term is not promoted")
    func fuzzyDuplicateNotPromoted() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Susurrus", category: .product))
        // Typo variant of an existing term must not enter the vocabulary.
        mgr.recordCorrection(
            raw: "we call it sysaurus today",
            edited: "we call it Sussurus today"
        )
        #expect(!vocab.entries().contains { $0.term == "Sussurus" })
        #expect(vocab.entries().count == 1)
    }

    @Test("Common-phrase match does not fast-path activate off a promoted replacement")
    func commonPhraseNoFastActivation() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "i spoke to and while about it",
            edited: "i spoke to Anwar about it"
        )
        let rule = mgr.rules().first { $0.match == "and while" }
        #expect(rule != nil)
        #expect(rule?.enabled == false)

        // Second sighting is real evidence — then it activates.
        mgr.recordCorrection(
            raw: "ping and while please",
            edited: "ping Anwar please"
        )
        #expect(mgr.rules().first { $0.match == "and while" }?.enabled == true)
    }

    @Test("Join/casing fix of common words still fast-path activates")
    func joinFixStillFastActivates() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "we use mark logic here",
            edited: "we use MarkLogic here"
        )
        #expect(mgr.activeRules().contains { $0.match == "mark logic" })
    }

    // MARK: - Learning-quality migration

    @Test("Migration removes lowercase common-word vocab and disables risky rules once")
    func learningQualityMigration() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "voice", category: .custom))
        vocab.addEntry(VocabularyEntry(term: "project", category: .custom))
        vocab.addEntry(VocabularyEntry(term: "MarkLogic", category: .technical))
        vocab.addEntry(VocabularyEntry(term: "grep", category: .technical))  // uncommon, kept
        mgr.addRule(CorrectionRule(match: "and while", replacement: "Anwar", enabled: true))
        mgr.addRule(CorrectionRule(match: "qay", replacement: "QA", enabled: true))
        // Risky-shaped but manual — user's deliberate choice, must survive.
        mgr.addRule(CorrectionRule(match: "you know", replacement: "Juno", enabled: true, source: .manual))

        let outcome = mgr.runLearningQualityMigration()

        #expect(Set(outcome.removedTerms) == ["voice", "project"])
        #expect(outcome.disabledRules == ["and while→Anwar"])
        #expect(vocab.entries().map(\.term).sorted() == ["MarkLogic", "grep"])
        #expect(mgr.rules().first { $0.match == "and while" }?.enabled == false)
        #expect(mgr.rules().first { $0.match == "qay" }?.enabled == true)
        // Manual rules are the user's deliberate choice — untouched.
        #expect(mgr.rules().first { $0.match == "you know" }?.enabled == true)

        // Second run is a no-op even if junk reappears.
        vocab.addEntry(VocabularyEntry(term: "news", category: .custom))
        let second = mgr.runLearningQualityMigration()
        #expect(second.removedTerms.isEmpty)
        #expect(vocab.entries().contains { $0.term == "news" })
    }

    // MARK: - Learning outcome surfacing (onLearn)

    @Test("onLearn fires when a rule activates on second sighting, not first")
    func onLearnFiresOnActivation() {
        let (mgr, _) = makeManagers()
        nonisolated(unsafe) var outcomes: [LearningOutcome] = []
        mgr.onLearn = { outcomes.append($0) }

        mgr.recordCorrection(
            raw: "reprocess it with core bee tonight",
            edited: "reprocess it with corb tonight"
        )
        // First sighting: rule recorded but inert — stay quiet.
        #expect(outcomes.isEmpty)

        mgr.recordCorrection(
            raw: "run core bee again",
            edited: "run corb again"
        )
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.activatedRules.first?.match == "core bee")
        #expect(outcomes.first?.activatedRules.first?.replacement == "corb")
    }

    @Test("onLearn reports vocabulary promotion")
    func onLearnReportsPromotion() {
        let (mgr, _) = makeManagers()
        nonisolated(unsafe) var outcomes: [LearningOutcome] = []
        mgr.onLearn = { outcomes.append($0) }

        mgr.recordCorrection(
            raw: "ask jayendra about it",
            edited: "ask Jayendra about it"
        )
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.promotedTerms == ["Jayendra"])
    }

    @Test("onLearn stays quiet for edits that teach nothing new")
    func onLearnQuietOnRepeatPromotion() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Jayendra", category: .person))
        nonisolated(unsafe) var outcomes: [LearningOutcome] = []
        mgr.onLearn = { outcomes.append($0) }

        // Pure punctuation/wording edit with no substitution to learn.
        mgr.recordCorrection(
            raw: "hello there everyone",
            edited: "hello there, everyone!"
        )
        #expect(outcomes.isEmpty)
    }

    @Test("Substitution edit creates a rule, active after two sightings")
    func ruleFromEdit() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "reprocess it with core bee tonight",
            edited: "reprocess it with corb tonight"
        )
        let first = mgr.rules().first { $0.match == "core bee" }
        #expect(first != nil)
        #expect(first?.replacement == "corb")
        #expect(first?.enabled == false)

        mgr.recordCorrection(
            raw: "run core bee again",
            edited: "run corb again"
        )
        let second = mgr.rules().first { $0.match == "core bee" }
        #expect(second?.hitCount == 2)
        #expect(second?.enabled == true)
    }

    @Test("Rule activates immediately when replacement is a proper noun")
    func properNounRuleActivatesImmediately() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "we use mark logic here",
            edited: "we use MarkLogic here"
        )
        let rule = mgr.activeRules().first { $0.match == "mark logic" }
        #expect(rule != nil)
        #expect(rule?.replacement == "MarkLogic")
    }

    @Test("Proper-noun replacement is promoted to vocabulary")
    func vocabPromotion() {
        let (mgr, vocab) = makeManagers()
        mgr.recordCorrection(
            raw: "ask jayendra about it",
            edited: "ask Jayendra about it"
        )
        #expect(vocab.entries().contains { $0.term == "Jayendra" })
    }

    @Test("ALLCAPS promotion guesses acronym category")
    func acronymPromotion() {
        let (mgr, vocab) = makeManagers()
        mgr.recordCorrection(
            raw: "the sparkle endpoint is slow",
            edited: "the SPARQL endpoint is slow"
        )
        let entry = vocab.entries().first { $0.term == "SPARQL" }
        #expect(entry?.category == .acronym)
    }

    @Test("Reversal edit disables the rule")
    func reversalDisables() {
        let (mgr, _) = makeManagers()
        mgr.addRule(CorrectionRule(match: "core bee", replacement: "CoRB", enabled: true))
        // User edits CoRB back to core bee — the rule was wrong for them.
        mgr.recordCorrection(
            raw: "run CoRB again",
            edited: "run core bee again"
        )
        #expect(mgr.activeRules().filter { $0.match == "core bee" }.isEmpty)
    }

    @Test("Unrelated edit mentioning the replacement does not disable the rule")
    func reversalNeedsWholeWordMatch() {
        let (mgr, _) = makeManagers()
        // Match is a substring of the replacement — the historic substring
        // check disabled this rule on any edit whose text contained
        // "Brinda" ("brinda" ⊃ "rinda").
        mgr.addRule(CorrectionRule(match: "rinda", replacement: "Brinda", enabled: true))
        mgr.recordCorrection(
            raw: "Brinda helped with the release",
            edited: "Brinda helped with the release notes"
        )
        #expect(mgr.activeRules().contains { $0.match == "rinda" })

        // A genuine reversal — whole word "rinda" in the edited text —
        // still disables it.
        mgr.recordCorrection(
            raw: "ask Brinda today",
            edited: "ask rinda today"
        )
        #expect(!mgr.activeRules().contains { $0.match == "rinda" })
    }

    @Test("Pure insertions and deletions do not create rules")
    func insertionsIgnored() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "ship it friday",
            edited: "ship it on friday please"
        )
        #expect(mgr.rules().isEmpty)
    }

    @Test("Long rewrites do not create sprawling rules")
    func longRewritesIgnored() {
        let (mgr, _) = makeManagers()
        mgr.recordCorrection(
            raw: "one two three four five six seven",
            edited: "alpha beta gamma delta epsilon zeta eta"
        )
        #expect(mgr.rules().isEmpty)
    }

    @Test("mismatchRegions aligns substitution in context")
    func alignment() {
        let regions = CorrectionLearningManager.mismatchRegions(
            ["use", "core", "bee", "tonight"],
            ["use", "corb", "tonight"]
        )
        #expect(regions.count == 1)
        #expect(regions[0].0 == 1..<3)
        #expect(regions[0].1 == 1..<2)
    }
}

@Suite("NotebookManager learning Tests")
struct NotebookLearningTests {

    @Test("Entry edits are recorded as corrections")
    func entryEditRecords() {
        let nb = NotebookManager.createForTesting()
        let corrections = CorrectionLearningManager.createForTesting()
        nb.correctionLearning = corrections

        let notebook = nb.createNotebook(name: "Test")
        nb.setActiveNotebookId(notebook.id)
        nb.appendToActiveNotebook(text: "we use mark logic here")
        let entry = nb.notebookEntries(id: notebook.id)[0]

        nb.updateEntry(notebookId: notebook.id, entryId: entry.id, newText: "we use MarkLogic here")
        #expect(corrections.allCorrections().count == 1)
        #expect(corrections.allCorrections()[0].editedText == "we use MarkLogic here")
    }

    @Test("Bias terms extracted from recent entries")
    func biasTerms() {
        let nb = NotebookManager.createForTesting()
        let notebook = nb.createNotebook(name: "Migration")
        nb.setActiveNotebookId(notebook.id)
        nb.appendToActiveNotebook(text: "Talked to Jayendra about the MarkLogic upgrade and the QAS pipeline.")

        let terms = nb.activeNotebookBiasTerms()
        #expect(terms.contains("Jayendra"))
        #expect(terms.contains("MarkLogic"))
        #expect(terms.contains("QAS"))
        #expect(!terms.contains("about"))
        #expect(!terms.contains("Talked"))
    }
}
