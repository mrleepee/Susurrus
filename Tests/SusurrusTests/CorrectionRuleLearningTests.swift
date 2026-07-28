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

    /// Replaces the former `joinFixStillFastActivates`, which asserted that a
    /// join fix mints a fast-activated rule. That contract is deliberately
    /// gone: the vocabulary pass already handles joins, so minting a rule
    /// added only exact-match risk. The behaviour users care about — the join
    /// still being corrected — is asserted below and pinned at the corrector.
    @Test("Join/casing fix is handled by vocabulary, with no rule minted")
    func joinFixHandledByVocabularyNotRule() {
        let (mgr, vocab) = makeManagers()
        mgr.recordCorrection(
            raw: "we use mark logic here",
            edited: "we use MarkLogic here"
        )
        // The term is the durable artefact — it also biases Whisper up front.
        #expect(vocab.entries().contains { $0.term == "MarkLogic" })
        #expect(!mgr.rules().contains { $0.match == "mark logic" })
    }

    @Test("Vocabulary alone still corrects 'mark logic' with zero rules")
    func markLogicSurvivesWithoutRules() {
        // The regression this whole change rests on: multi-word windows skip
        // the single-word CommonWords guard, so the exact-normalized join
        // reaches MarkLogic without any rule involved.
        let out = TranscriptCorrector().correct(
            "we use mark logic here",
            vocabulary: [VocabularyEntry(term: "MarkLogic", category: .technical)],
            rules: []
        )
        #expect(out.text == "we use MarkLogic here")
    }

    // MARK: - Vocabulary-first suppression

    @Test("Single-word fix reachable by fuzzy vocabulary mints no rule")
    func fuzzyReachableMintsNoRule() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Abhishek", category: .person))
        mgr.recordCorrection(raw: "i asked abishek about it", edited: "i asked Abhishek about it")
        // The fuzzy vocabulary pass already repairs "abishek"; a rule would
        // only add exact-match risk for a mangling Whisper never repeats.
        #expect(!mgr.rules().contains { $0.match == "abishek" })
    }

    @Test("A common-word match still mints a rule — vocabulary refuses to touch it")
    func commonWordMatchStillMintsRule() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Wattar", category: .person))
        // "water" is a common word, so applyVocabulary's single-word guard
        // blocks it. Suppressing the rule here would silently lose the fix.
        mgr.recordCorrection(raw: "ask water about it", edited: "ask Wattar about it")
        #expect(mgr.rules().contains { $0.match == "water" })
    }

    @Test("Suppression retires an existing learned rule but spares manual ones")
    func suppressionSparesManualRules() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Abhishek", category: .person))
        mgr.addRule(CorrectionRule(match: "abishek", replacement: "Abhishek", source: .manual))
        mgr.recordCorrection(raw: "i asked abishek", edited: "i asked Abhishek")
        // A hand-written rule is the user's explicit instruction; never
        // disable it on the app's own inference.
        #expect(mgr.rules().first { $0.match == "abishek" }?.enabled == true)
    }

    // MARK: - Multi-word corroboration

    @Test("Multi-word match never fast-paths, even with known vocabulary")
    func multiWordNeverFastPaths() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        // The live bug: "URIs" was known, so this activated off one sighting
        // and then rewrote every legitimate "your eyes".
        mgr.recordCorrection(raw: "check your eyes now", edited: "check URIs now")
        #expect(mgr.rules().first { $0.match == "your eyes" }?.enabled == false)
    }

    @Test("Ordinary English survives a single-sighting multi-word edit")
    func ordinaryEnglishNotCorrupted() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        mgr.recordCorrection(raw: "check your eyes now", edited: "check URIs now")
        let out = TranscriptCorrector().correct(
            "your eyes look tired",
            vocabulary: vocab.entries(),
            rules: mgr.activeRules()
        )
        #expect(out.text == "your eyes look tired")
    }

    @Test("A corroborated multi-word rule does activate")
    func multiWordActivatesOnSecondSighting() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        mgr.recordCorrection(raw: "check your eyes now", edited: "check URIs now")
        mgr.recordCorrection(raw: "list your eyes please", edited: "list URIs please")
        // Two independent sightings are real evidence, not a coincidence.
        #expect(mgr.rules().first { $0.match == "your eyes" }?.enabled == true)
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
        // "Susurrus" is restored by the app-name repair in migration 3.
        #expect(vocab.entries().map(\.term).sorted() == ["MarkLogic", "Susurrus", "grep"])
        #expect(outcome.addedTerms == ["Susurrus"])
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

    @Test("Single-word rule activates immediately when replacement is a proper noun")
    func properNounRuleActivatesImmediately() {
        let (mgr, _) = makeManagers()
        // "pancage"/"Pankaj" have different phonetic keys, so the fuzzy
        // vocabulary pass cannot reach this — the rule genuinely earns its
        // place and still fast-paths. (Previously asserted with "mark logic"
        // → "MarkLogic", which vocabulary now handles without any rule.)
        mgr.recordCorrection(
            raw: "i asked pancage about it",
            edited: "i asked Pankaj about it"
        )
        let rule = mgr.activeRules().first { $0.match == "pancage" }
        #expect(rule != nil)
        #expect(rule?.replacement == "Pankaj")
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
