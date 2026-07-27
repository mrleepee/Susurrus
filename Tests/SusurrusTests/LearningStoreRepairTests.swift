import Foundation
import Testing
@testable import SusurrusKit

/// Migration 3: repairs learning data written before the vocabulary-first and
/// multi-word-corroboration guards existed. Every rule sweep is restricted to
/// `.learned` — a manual rule is the user's explicit instruction.
@Suite("Learning store repair Tests")
struct LearningStoreRepairTests {

    private func makeManagers() -> (CorrectionLearningManager, VocabularyManager) {
        let vocab = VocabularyManager.createForTesting()
        // The seed would otherwise supply terms the sweeps react to.
        vocab.setEntries([])
        let mgr = CorrectionLearningManager(
            vocabularyManager: vocab,
            defaults: UserDefaults(suiteName: "com.susurrus.repair.test.\(UUID().uuidString)")!
        )
        return (mgr, vocab)
    }

    // MARK: - Rule sweeps

    @Test("Retires rules the vocabulary pass already covers")
    func retiresVocabularyRedundantRules() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Abhishek", category: .person))
        mgr.addRule(CorrectionRule(match: "abishek", replacement: "Abhishek", hitCount: 3))
        let result = mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "abishek" }?.enabled == false)
        #expect(result.disabledRules.contains("abishek→Abhishek"))
    }

    @Test("Keeps a rule whose match vocabulary refuses to rewrite")
    func keepsRuleVocabularyCannotCover() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Pankaj", category: .person))
        // Different phonetic key — fuzzy matching cannot reach it, so the
        // rule is the only thing delivering this fix.
        mgr.addRule(CorrectionRule(match: "pancage", replacement: "Pankaj", hitCount: 3))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "pancage" }?.enabled == true)
    }

    @Test("Retires multi-word rules that activated on a single sighting")
    func retiresUncorroboratedMultiWord() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        mgr.addRule(CorrectionRule(match: "your eyes", replacement: "URIs", hitCount: 1))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "your eyes" }?.enabled == false)
    }

    @Test("Keeps a multi-word rule that was genuinely corroborated")
    func keepsCorroboratedMultiWord() {
        let (mgr, _) = makeManagers()
        // Two sightings, and no vocabulary term can produce it — this rule is
        // the only thing delivering the fix, so corroboration earned its place.
        mgr.addRule(CorrectionRule(match: "sub query", replacement: "sub-query", hitCount: 2))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "sub query" }?.enabled == true)
    }

    @Test("Ordinary English is safe again after repair")
    func ordinaryEnglishRestored() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        mgr.addRule(CorrectionRule(match: "your eyes", replacement: "URIs", hitCount: 1))
        mgr.runLearningQualityMigration()
        let out = TranscriptCorrector().correct(
            "your eyes look tired",
            vocabulary: vocab.entries(),
            rules: mgr.activeRules()
        )
        #expect(out.text == "your eyes look tired")
    }

    // MARK: - Manual rules are never touched (one per sweep)

    @Test("Manual rule survives the vocabulary-redundancy sweep")
    func manualSurvivesRedundancySweep() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Abhishek", category: .person))
        mgr.addRule(CorrectionRule(match: "abishek", replacement: "Abhishek", hitCount: 3, source: .manual))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "abishek" }?.enabled == true)
    }

    @Test("Manual rule survives the multi-word sweep")
    func manualSurvivesMultiWordSweep() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "URIs", category: .technical))
        mgr.addRule(CorrectionRule(match: "your eyes", replacement: "URIs", hitCount: 1, source: .manual))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "your eyes" }?.enabled == true)
    }

    @Test("Manual rule survives the risky-common-phrase sweep")
    func manualSurvivesCommonPhraseSweep() {
        let (mgr, _) = makeManagers()
        mgr.addRule(CorrectionRule(match: "and while", replacement: "Anwar", hitCount: 1, source: .manual))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "and while" }?.enabled == true)
    }

    // MARK: - Vocabulary repair

    @Test("Restores the canonical app name and drops the misspelling")
    func repairsAppName() {
        let (mgr, vocab) = makeManagers()
        // Production state: the misspelling had the usage, the correct
        // spelling was absent entirely.
        vocab.addEntry(VocabularyEntry(term: "Sussurus", category: .product, useCount: 5))
        let result = mgr.runLearningQualityMigration()
        let names = vocab.entries().filter { $0.term.lowercased().hasPrefix("sus") }
        #expect(names.count == 1)
        #expect(names.first?.term == "Susurrus")
        #expect(result.addedTerms.contains("Susurrus"))
        #expect(result.removedTerms.contains("Sussurus"))
    }

    @Test("Retires a rule that would reintroduce a deleted term")
    func retiresRuleFeedingRemovedTerm() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Sussurus", category: .product, useCount: 5))
        // The live pairing: the misspelling in vocabulary, plus a rule that
        // keeps producing it. Removing only the term would leave the rule
        // teaching it right back.
        mgr.addRule(CorrectionRule(match: "sysaurus", replacement: "Sussurus", hitCount: 1))
        mgr.runLearningQualityMigration()
        #expect(mgr.rules().first { $0.match == "sysaurus" }?.enabled == false)
        #expect(!vocab.entries().contains { $0.term == "Sussurus" })
        #expect(vocab.entries().contains { $0.term == "Susurrus" })
    }

    @Test("Deduplicates near-identical terms, keeping the more-used one")
    func dedupesNearDuplicates() {
        let (mgr, vocab) = makeManagers()
        vocab.setEntries([
            VocabularyEntry(term: "Harandh", category: .person, useCount: 0),
            VocabularyEntry(term: "Harnadh", category: .person, useCount: 3),
        ])
        mgr.runLearningQualityMigration()
        let remaining = vocab.entries().filter { $0.term.lowercased().hasPrefix("har") }
        #expect(remaining.count == 1)
        #expect(remaining.first?.term == "Harnadh")
    }

    @Test("Removes junk terms that escaped the CommonWords sweep")
    func removesJunkTerms() {
        let (mgr, vocab) = makeManagers()
        vocab.setEntries([
            VocabularyEntry(term: "delta", category: .custom),
            VocabularyEntry(term: "dictation", category: .custom),
            VocabularyEntry(term: "exclude", category: .custom),
            VocabularyEntry(term: "SPARQL", category: .technical),
        ])
        mgr.runLearningQualityMigration()
        let terms = Set(vocab.entries().map(\.term))
        #expect(!terms.contains("delta"))
        #expect(!terms.contains("dictation"))
        #expect(!terms.contains("exclude"))
        // Legitimate rare terms stay — unused is not the same as junk.
        #expect(terms.contains("SPARQL"))
    }

    @Test("Never-used but legitimate terms are preserved")
    func preservesUnusedLegitimateTerms() {
        let (mgr, vocab) = makeManagers()
        // All zero-use, all deliberately kept: seeded defaults and colleague
        // names are unused only because they haven't come up recently.
        vocab.setEntries([
            VocabularyEntry(term: "CoRB", category: .technical),
            VocabularyEntry(term: "Schengen", category: .place),
            VocabularyEntry(term: "Kashish", category: .person),
            VocabularyEntry(term: "Pankaj", category: .person),
        ])
        mgr.runLearningQualityMigration()
        let terms = Set(vocab.entries().map(\.term))
        // All four survive. (The app-name restore also adds "Susurrus", which
        // is why this asserts survival rather than an exact count.)
        #expect(terms.isSuperset(of: ["CoRB", "Schengen", "Kashish", "Pankaj"]))
    }

    // MARK: - One-shot behaviour

    @Test("Runs once; a second call changes nothing")
    func runsOnlyOnce() {
        let (mgr, vocab) = makeManagers()
        vocab.addEntry(VocabularyEntry(term: "Abhishek", category: .person))
        mgr.addRule(CorrectionRule(match: "abishek", replacement: "Abhishek", hitCount: 3))
        let first = mgr.runLearningQualityMigration()
        #expect(!first.disabledRules.isEmpty)

        let rulesAfter = mgr.rules()
        let vocabAfter = vocab.entries()
        let second = mgr.runLearningQualityMigration()
        #expect(second.removedTerms.isEmpty)
        #expect(second.addedTerms.isEmpty)
        #expect(second.disabledRules.isEmpty)
        #expect(mgr.rules() == rulesAfter)
        #expect(vocab.entries() == vocabAfter)
    }

    @Test("Empty store is a no-op but still marks the migration done")
    func emptyStoreIsNoOp() {
        let (mgr, vocab) = makeManagers()
        let result = mgr.runLearningQualityMigration()
        #expect(result.disabledRules.isEmpty)
        // Only the app-name restore should have run.
        #expect(vocab.entries().map(\.term) == ["Susurrus"])
        #expect(mgr.runLearningQualityMigration().addedTerms.isEmpty)
    }

    // MARK: - Seed integrity

    @Test("Seed no longer ships the duplicate name")
    func seedHasNoDuplicate() {
        // createForTesting() skips seeding, so build one that actually seeds.
        let vocab = VocabularyManager(
            defaults: UserDefaults(suiteName: "com.susurrus.seed.test.\(UUID().uuidString)")!
        )
        let terms = vocab.entries().map(\.term)
        #expect(terms.contains("Harnadh"))
        #expect(!terms.contains("Harandh"))
        #expect(terms.contains("Susurrus"))
        // Every seeded line must have parsed as a real term.
        #expect(!terms.contains { $0.hasPrefix("#") })
    }
}
