import Foundation
import Testing
@testable import SusurrusKit

@Suite("TranscriptCorrector Tests")
struct TranscriptCorrectorTests {

    private let corrector = TranscriptCorrector()

    private func vocab(_ terms: [(String, VocabularyCategory)]) -> [VocabularyEntry] {
        terms.map { VocabularyEntry(term: $0.0, category: $0.1) }
    }

    // MARK: - No-op safety

    @Test("Empty vocab and rules leave text untouched")
    func noopWithoutConfig() {
        let outcome = corrector.correct("Hello there, this is a test.", vocabulary: [], rules: [])
        #expect(outcome.text == "Hello there, this is a test.")
        #expect(outcome.changes.isEmpty)
    }

    @Test("Clean text with irrelevant vocab is unchanged")
    func cleanTextUnchanged() {
        let outcome = corrector.correct(
            "The meeting is at three tomorrow.",
            vocabulary: vocab([("MarkLogic", .technical), ("Susurrus", .product)]),
            rules: []
        )
        #expect(outcome.text == "The meeting is at three tomorrow.")
        #expect(outcome.changes.isEmpty)
    }

    // MARK: - Exact-normalized vocabulary matches

    @Test("Split compound joins to vocab term: mark logic → MarkLogic")
    func splitCompoundJoins() {
        let outcome = corrector.correct(
            "We use mark logic for the database.",
            vocabulary: vocab([("MarkLogic", .technical)]),
            rules: []
        )
        #expect(outcome.text == "We use MarkLogic for the database.")
        #expect(outcome.changes.count == 1)
    }

    @Test("Casing enforced on exact hit: sparql → SPARQL")
    func casingEnforced() {
        let outcome = corrector.correct(
            "Write the sparql query first.",
            vocabulary: vocab([("SPARQL", .technical)]),
            rules: []
        )
        #expect(outcome.text == "Write the SPARQL query first.")
    }

    @Test("Acronym category forces uppercase")
    func acronymUppercased() {
        let outcome = corrector.correct(
            "Check the qas pipeline.",
            vocabulary: [VocabularyEntry(term: "qas", category: .acronym)],
            rules: []
        )
        #expect(outcome.text == "Check the QAS pipeline.")
    }

    @Test("Multi-word term already correct is untouched")
    func correctMultiWordUntouched() {
        let outcome = corrector.correct(
            "The Trust Signals project is live.",
            vocabulary: vocab([("Trust Signals", .project)]),
            rules: []
        )
        #expect(outcome.text == "The Trust Signals project is live.")
        #expect(outcome.changes.isEmpty)
    }

    @Test("No join across sentence punctuation")
    func noJoinAcrossPunctuation() {
        let outcome = corrector.correct(
            "I met Mark. Logic is fun.",
            vocabulary: vocab([("MarkLogic", .technical)]),
            rules: []
        )
        #expect(outcome.text == "I met Mark. Logic is fun.")
    }

    // MARK: - Fuzzy vocabulary matches

    @Test("Phonetic fuzzy: sparkle → SPARQL")
    func fuzzySparkle() {
        let outcome = corrector.correct(
            "Run the sparkle query against the store.",
            vocabulary: vocab([("SPARQL", .technical)]),
            rules: []
        )
        #expect(outcome.text == "Run the SPARQL query against the store.")
    }

    @Test("Misspelling fuzzy: susurus → Susurrus")
    func fuzzyMisspelling() {
        let outcome = corrector.correct(
            "I opened susurus and started dictating.",
            vocabulary: vocab([("Susurrus", .product)]),
            rules: []
        )
        #expect(outcome.text == "I opened Susurrus and started dictating.")
    }

    @Test("Split fuzzy: data vid → Datavid")
    func fuzzySplit() {
        let outcome = corrector.correct(
            "The data vid team shipped it.",
            vocabulary: vocab([("Datavid", .company)]),
            rules: []
        )
        #expect(outcome.text == "The Datavid team shipped it.")
    }

    // MARK: - False-positive guards

    @Test("Common word never fuzzy-corrected: person stays person")
    func commonWordGuard() {
        let outcome = corrector.correct(
            "That person is waiting outside.",
            vocabulary: vocab([("Pearson", .person)]),
            rules: []
        )
        #expect(outcome.text == "That person is waiting outside.")
        #expect(outcome.changes.isEmpty)
    }

    @Test("Common word never case-corrected: may stays lowercase")
    func commonWordCaseGuard() {
        let outcome = corrector.correct(
            "It may rain later.",
            vocabulary: vocab([("May", .person)]),
            rules: []
        )
        #expect(outcome.text == "It may rain later.")
    }

    @Test("Short words are not fuzzy-matched")
    func shortWordsSkipped() {
        let outcome = corrector.correct(
            "The cat sat on the mat.",
            vocabulary: vocab([("CATS", .acronym)]),
            rules: []
        )
        #expect(outcome.text == "The cat sat on the mat.")
    }

    @Test("Distant words are not fuzzy-matched")
    func distantWordsSkipped() {
        let outcome = corrector.correct(
            "The sprinkler is broken.",
            vocabulary: vocab([("SPARQL", .technical)]),
            rules: []
        )
        #expect(outcome.text == "The sprinkler is broken.")
    }

    // MARK: - Rules

    @Test("Learned rule applies")
    func ruleApplies() {
        let rule = CorrectionRule(match: "core b", replacement: "CoRB")
        let outcome = corrector.correct(
            "Reprocess it with core b overnight.",
            vocabulary: [],
            rules: [rule]
        )
        #expect(outcome.text == "Reprocess it with CoRB overnight.")
    }

    @Test("Rule preserves sentence-initial capitalization for lowercase replacements")
    func ruleSentenceCase() {
        let rule = CorrectionRule(match: "gonna", replacement: "going to")
        let outcome = corrector.correct(
            "Gonna ship it today.",
            vocabulary: [],
            rules: [rule]
        )
        #expect(outcome.text == "Going to ship it today.")
    }

    @Test("Rule with intentional casing is not sentence-cased")
    func ruleKeepsIntentionalCasing() {
        let rule = CorrectionRule(match: "eye phone", replacement: "iPhone")
        let outcome = corrector.correct(
            "Eye phone is charging.",
            vocabulary: [],
            rules: [rule]
        )
        #expect(outcome.text == "iPhone is charging.")
    }

    @Test("Disabled rule is ignored")
    func disabledRuleIgnored() {
        let rule = CorrectionRule(match: "core b", replacement: "CoRB", enabled: false)
        let outcome = corrector.correct(
            "Use core b for this.",
            vocabulary: [],
            rules: [rule]
        )
        #expect(outcome.text == "Use core b for this.")
    }

    @Test("Rules run before vocab and both apply")
    func rulesAndVocabCompose() {
        let rule = CorrectionRule(match: "core b", replacement: "CoRB")
        let outcome = corrector.correct(
            "Use core b with mark logic.",
            vocabulary: vocab([("MarkLogic", .technical)]),
            rules: [rule]
        )
        #expect(outcome.text == "Use CoRB with MarkLogic.")
        #expect(outcome.changes.count == 2)
    }

    // MARK: - Metrics helpers

    @Test("Phonetic keys collapse confusable spellings")
    func phoneticKeys() {
        #expect(TranscriptCorrector.phoneticKey("sparql") == TranscriptCorrector.phoneticKey("sparkle"))
        #expect(TranscriptCorrector.phoneticKey("susurrus") == TranscriptCorrector.phoneticKey("susurus"))
        #expect(TranscriptCorrector.phoneticKey("marklogic") != TranscriptCorrector.phoneticKey("markdown"))
    }

    @Test("Damerau-Levenshtein handles transpositions")
    func editDistance() {
        #expect(TranscriptCorrector.damerauLevenshtein("abc", "abc") == 0)
        #expect(TranscriptCorrector.damerauLevenshtein("abc", "acb") == 1)
        #expect(TranscriptCorrector.damerauLevenshtein("sparkle", "sparql") == 2)
        #expect(TranscriptCorrector.damerauLevenshtein("", "abc") == 3)
    }

    @Test("Normalization strips case, spaces, and punctuation")
    func normalization() {
        #expect(TranscriptCorrector.normalize("Mark Logic") == "marklogic")
        #expect(TranscriptCorrector.normalize("Lead's") == "leads")
        #expect(TranscriptCorrector.normalize("242 C3") == "242c3")
    }
}

@Suite("CorrectionRule storage Tests")
struct CorrectionRuleStorageTests {

    @Test("addRule stores and activeRules filters disabled")
    func addAndFilter() {
        let mgr = CorrectionLearningManager.createForTesting()
        mgr.addRule(CorrectionRule(match: "core b", replacement: "CoRB"))
        mgr.addRule(CorrectionRule(match: "gonna", replacement: "going to", enabled: false))
        #expect(mgr.rules().count == 2)
        #expect(mgr.activeRules().count == 1)
        #expect(mgr.activeRules()[0].replacement == "CoRB")
    }

    @Test("addRule merges same match and replacement by bumping hitCount")
    func mergesSameRule() {
        let mgr = CorrectionLearningManager.createForTesting()
        mgr.addRule(CorrectionRule(match: "core b", replacement: "CoRB"))
        mgr.addRule(CorrectionRule(match: "Core B", replacement: "CoRB"))
        let all = mgr.rules()
        #expect(all.count == 1)
        #expect(all[0].hitCount == 2)
    }

    @Test("addRule with different replacement supersedes")
    func supersedesDifferentReplacement() {
        let mgr = CorrectionLearningManager.createForTesting()
        mgr.addRule(CorrectionRule(match: "core b", replacement: "CoRB"))
        mgr.addRule(CorrectionRule(match: "core b", replacement: "Corb2"))
        let all = mgr.rules()
        #expect(all.count == 1)
        #expect(all[0].replacement == "Corb2")
    }

    @Test("removeRule and setRuleEnabled work")
    func removeAndToggle() {
        let mgr = CorrectionLearningManager.createForTesting()
        let rule = CorrectionRule(match: "core b", replacement: "CoRB")
        mgr.addRule(rule)
        mgr.setRuleEnabled(id: rule.id, enabled: false)
        #expect(mgr.activeRules().isEmpty)
        mgr.removeRule(id: rule.id)
        #expect(mgr.rules().isEmpty)
    }
}
