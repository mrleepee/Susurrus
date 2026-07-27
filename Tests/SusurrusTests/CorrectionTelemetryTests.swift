import Foundation
import Testing
@testable import SusurrusKit

/// Fire telemetry: which rule or vocabulary entry actually repaired a
/// transcript. Before this, `hitCount` counted user edits and was displayed as
/// "fixes", so a rule that had never corrected anything looked identical to one
/// doing real work.
@Suite("Correction fire telemetry Tests")
struct CorrectionTelemetryTests {

    private func manager() -> CorrectionLearningManager {
        let suite = UserDefaults(suiteName: "com.susurrus.fire.test.\(UUID().uuidString)")!
        return CorrectionLearningManager(defaults: suite)
    }

    // MARK: - Provenance

    @Test("Rule-driven change carries the id of the rule that fired")
    func ruleProvenance() {
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        let out = TranscriptCorrector().correct("the qay team", vocabulary: [], rules: [rule])
        #expect(out.text == "the QA team")
        #expect(out.changes.count == 1)
        #expect(out.changes[0].firedRuleID == rule.id)
        #expect(out.changes[0].firedVocabularyID == nil)
    }

    @Test("Vocabulary-driven change carries the id of the entry that fired")
    func vocabProvenance() {
        let entry = VocabularyEntry(term: "MarkLogic", category: .technical)
        let out = TranscriptCorrector().correct("we use marklogic", vocabulary: [entry], rules: [])
        #expect(out.changes.count == 1)
        #expect(out.changes[0].firedVocabularyID == entry.id)
        #expect(out.changes[0].firedRuleID == nil)
    }

    @Test("Mixed text credits each layer separately")
    func mixedProvenance() {
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        let entry = VocabularyEntry(term: "MarkLogic", category: .technical)
        let out = TranscriptCorrector().correct("qay tested marklogic", vocabulary: [entry], rules: [rule])
        #expect(out.changes.compactMap(\.firedRuleID) == [rule.id])
        #expect(out.changes.compactMap(\.firedVocabularyID) == [entry.id])
    }

    @Test("Colliding matches credit the tie-break winner, not the loser")
    func tieBreakCreditsWinner() {
        // applyRules dedupes by match, keeping the higher hitCount.
        let loser = CorrectionRule(match: "qay", replacement: "QA", hitCount: 1)
        let winner = CorrectionRule(match: "qay", replacement: "QA", hitCount: 9)
        let out = TranscriptCorrector().correct("qay", vocabulary: [], rules: [loser, winner])
        #expect(out.changes[0].firedRuleID == winner.id)
    }

    @Test("A rule that changes nothing records no fire")
    func noOpRecordsNothing() {
        // Replacement equals the input, so there is nothing to credit.
        let rule = CorrectionRule(match: "qa", replacement: "QA")
        let out = TranscriptCorrector().correct("QA", vocabulary: [], rules: [rule])
        #expect(out.changes.isEmpty)
    }

    // MARK: - The corrector must stay pure

    @Test("correct() never persists — the preview runs it ~10Hz")
    func correctorPerformsNoWrites() {
        let m = manager()
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        m.addRule(rule)
        let before = m.rules()
        let corrector = TranscriptCorrector()
        for _ in 0..<100 {
            _ = corrector.correct("qay qay qay", vocabulary: [], rules: m.activeRules())
        }
        #expect(m.rules() == before)
        #expect(m.rules().allSatisfy { $0.fireCount == 0 })
    }

    // MARK: - recordFires

    @Test("recordFires credits the rule and stamps the time")
    func recordFiresCredits() {
        let m = manager()
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        m.addRule(rule)
        m.recordFires(ruleIDs: [rule.id])
        let stored = m.rules().first { $0.id == rule.id }
        #expect(stored?.fireCount == 1)
        #expect(stored?.lastFiredAt != nil)
    }

    @Test("Repeats within one call aggregate")
    func recordFiresAggregates() {
        let m = manager()
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        m.addRule(rule)
        m.recordFires(ruleIDs: [rule.id, rule.id, rule.id])
        #expect(m.rules().first?.fireCount == 3)
    }

    @Test("Unknown ids cause no write at all")
    func recordFiresUnknownIsNoOp() {
        let m = manager()
        m.addRule(CorrectionRule(match: "qay", replacement: "QA"))
        let before = m.rules()
        m.recordFires(ruleIDs: [UUID()])
        #expect(m.rules() == before)
    }

    @Test("Empty input is a no-op")
    func recordFiresEmpty() {
        let m = manager()
        m.addRule(CorrectionRule(match: "qay", replacement: "QA"))
        let before = m.rules()
        m.recordFires(ruleIDs: [])
        #expect(m.rules() == before)
    }

    @Test("Re-teaching an existing rule does not inflate its fire count")
    func addRuleDoesNotMergeFireCount() {
        let m = manager()
        let rule = CorrectionRule(match: "qay", replacement: "QA")
        m.addRule(rule)
        m.recordFires(ruleIDs: [rule.id, rule.id])
        // Same match and replacement seen again: hitCount rises, fireCount holds.
        m.addRule(CorrectionRule(match: "qay", replacement: "QA"))
        let stored = m.rules().first
        #expect(stored?.hitCount == 2)
        #expect(stored?.fireCount == 2)
    }

    // MARK: - Vocabulary fixes

    @Test("recordFixes credits only the entry that actually fired")
    func vocabRecordFixes() {
        let suite = UserDefaults(suiteName: "com.susurrus.fix.test.\(UUID().uuidString)")!
        let vm = VocabularyManager(defaults: suite)
        vm.setEntries([
            VocabularyEntry(term: "MarkLogic", category: .technical),
            VocabularyEntry(term: "SPARQL", category: .technical),
        ])
        let target = vm.entries().first { $0.term == "MarkLogic" }!
        vm.recordFixes(ids: [target.id, target.id])
        #expect(vm.entries().first { $0.term == "MarkLogic" }?.fixCount == 2)
        // The other term appeared in no change, so it is not credited.
        #expect(vm.entries().first { $0.term == "SPARQL" }?.fixCount == nil)
    }

    // MARK: - Legacy decode (guards a silent total wipe)

    @Test("Rules stored before telemetry decode with fireCount 0")
    func legacyRulesDecode() throws {
        // Exactly the on-disk shape today: no fireCount, no lastFiredAt.
        // rules() is `(try? decode) ?? []`, so a throw here would erase
        // every rule the user has ever taught.
        let legacy = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","match":"qay","replacement":"QA",
          "hitCount":3,"enabled":true,"createdAt":775000000,"source":"learned"}]
        """
        let decoded = try JSONDecoder().decode([CorrectionRule].self, from: Data(legacy.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].match == "qay")
        #expect(decoded[0].replacement == "QA")
        #expect(decoded[0].hitCount == 3)
        #expect(decoded[0].enabled)
        #expect(decoded[0].source == .learned)
        #expect(decoded[0].fireCount == 0)
        #expect(decoded[0].lastFiredAt == nil)
    }

    @Test("A store mixing old and new rows decodes wholesale")
    func mixedLegacyDecode() throws {
        let mixed = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","match":"qay","replacement":"QA",
          "hitCount":1,"enabled":true,"createdAt":775000000,"source":"learned"},
         {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","match":"rinda","replacement":"Brinda",
          "hitCount":2,"enabled":false,"createdAt":775000001,"source":"manual",
          "fireCount":7,"lastFiredAt":775000002}]
        """
        let decoded = try JSONDecoder().decode([CorrectionRule].self, from: Data(mixed.utf8))
        #expect(decoded.count == 2)
        #expect(decoded[0].fireCount == 0)
        #expect(decoded[1].fireCount == 7)
        #expect(decoded[1].lastFiredAt != nil)
        #expect(decoded[1].source == .manual)
    }

    @Test("Encode/decode round-trips without loss")
    func roundTrip() throws {
        let rule = CorrectionRule(match: "your eyes", replacement: "URIs", hitCount: 4,
                                  enabled: false, source: .manual,
                                  fireCount: 11, lastFiredAt: Date(timeIntervalSince1970: 775))
        let data = try JSONEncoder().encode([rule])
        let back = try JSONDecoder().decode([CorrectionRule].self, from: data)
        #expect(back == [rule])
    }

    @Test("Legacy vocabulary entries decode with fixCount nil")
    func legacyVocabDecode() throws {
        let legacy = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","term":"MarkLogic",
          "category":"technical","useCount":22}]
        """
        let decoded = try JSONDecoder().decode([VocabularyEntry].self, from: Data(legacy.utf8))
        #expect(decoded[0].term == "MarkLogic")
        #expect(decoded[0].useCount == 22)
        #expect(decoded[0].fixCount == nil)
    }
}
