import Foundation
import Testing
@testable import SusurrusKit

@Suite("CorrectionLearningManager Tests")
struct CorrectionLearningManagerTests {

    private func makeManager() -> CorrectionLearningManager {
        CorrectionLearningManager.createForTesting()
    }

    // MARK: - recordCorrection

    @Test("recordCorrection stores a pair")
    func recordStores() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "hello world", edited: "Hello World")
        #expect(mgr.allCorrections().count == 1)
        #expect(mgr.allCorrections()[0].rawText == "hello world")
        #expect(mgr.allCorrections()[0].editedText == "Hello World")
    }

    @Test("recordCorrection ignores identical raw and edited")
    func ignoresIdentical() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "same", edited: "same")
        #expect(mgr.allCorrections().isEmpty)
    }

    @Test("Newest correction appears first")
    func newestFirst() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "a", edited: "A")
        mgr.recordCorrection(raw: "b", edited: "B")
        let all = mgr.allCorrections()
        #expect(all[0].rawText == "b")
        #expect(all[1].rawText == "a")
    }

    @Test("Caps at maxPairs (50)")
    func capsAtMax() {
        let mgr = makeManager()
        for i in 0..<55 {
            mgr.recordCorrection(raw: "raw\(i)", edited: "edited\(i)")
        }
        #expect(mgr.allCorrections().count == CorrectionLearningManager.maxPairs)
        // Newest should be preserved: "raw54" at index 0
        #expect(mgr.allCorrections()[0].rawText == "raw54")
    }

    // MARK: - relevantCorrections

    @Test("relevantCorrections returns empty when no pairs stored")
    func relevantEmpty() {
        let mgr = makeManager()
        let result = mgr.relevantCorrections(for: "some text", limit: 5)
        #expect(result.isEmpty)
    }

    @Test("relevantCorrections returns ranked results")
    func relevantRanked() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "the data bid project", edited: "The DataBid project")
        mgr.recordCorrection(raw: "hello world", edited: "Hello World")
        let result = mgr.relevantCorrections(for: "data bid update", limit: 5)
        #expect(!result.isEmpty)
        // The first result should be the one with more word overlap
        #expect(result[0].rawText == "the data bid project")
    }

    @Test("relevantCorrections respects limit")
    func relevantLimit() {
        let mgr = makeManager()
        for i in 0..<10 {
            mgr.recordCorrection(raw: "word\(i) test", edited: "Word\(i) test")
        }
        let result = mgr.relevantCorrections(for: "test", limit: 3)
        #expect(result.count == 3)
    }

    // MARK: - fewShotString

    @Test("fewShotString returns empty when no pairs")
    func fewShotEmpty() {
        let mgr = makeManager()
        #expect(mgr.fewShotString(for: "text", limit: 5) == "")
    }

    @Test("fewShotString formats pairs")
    func fewShotFormat() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "databid", edited: "DataBid")
        let result = mgr.fewShotString(for: "databid", limit: 5)
        #expect(result.contains("Raw: \"databid\""))
        #expect(result.contains("Fixed: \"DataBid\""))
    }

    // MARK: - clearCorrections

    @Test("clearCorrections removes all pairs")
    func clearRemoves() {
        let mgr = makeManager()
        mgr.recordCorrection(raw: "a", edited: "b")
        mgr.recordCorrection(raw: "c", edited: "d")
        mgr.clearCorrections()
        #expect(mgr.allCorrections().isEmpty)
    }

    // MARK: - Proper noun extraction

    @Test("Proper noun corrections auto-added to vocabulary")
    func properNounExtraction() {
        let vocab = VocabularyManager.createForTesting()
        let mgr = CorrectionLearningManager(vocabularyManager: vocab, defaults: UserDefaults(suiteName: "com.susurrus.correction.propnouns.\(UUID().uuidString)")!)
        mgr.recordCorrection(raw: "databid is great", edited: "DataBid is great")
        let entries = vocab.entries()
        #expect(entries.contains(where: { $0.term == "DataBid" }))
    }

    @Test("Non-case changes not added to vocabulary")
    func nonCaseChangesNotAdded() {
        let vocab = VocabularyManager.createForTesting()
        let mgr = CorrectionLearningManager(vocabularyManager: vocab, defaults: UserDefaults(suiteName: "com.susurrus.correction.noncase.\(UUID().uuidString)")!)
        mgr.recordCorrection(raw: "the project", edited: "my project")
        #expect(vocab.entries().isEmpty)
    }

    @Test("Duplicate proper nouns not added twice")
    func duplicateProperNounsSkipped() {
        let vocab = VocabularyManager.createForTesting()
        let defaults = UserDefaults(suiteName: "com.susurrus.correction.dupnouns.\(UUID().uuidString)")!
        let mgr = CorrectionLearningManager(vocabularyManager: vocab, defaults: defaults)
        mgr.recordCorrection(raw: "databid", edited: "DataBid")
        mgr.recordCorrection(raw: "databid", edited: "DataBid")
        let entries = vocab.entries().filter { $0.term == "DataBid" }
        #expect(entries.count == 1)
    }

    // MARK: - Persistence

    @Test("Corrections persist across instances")
    func persistence() {
        let suite = "com.susurrus.correction.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let writer = CorrectionLearningManager(defaults: defaults)
        writer.recordCorrection(raw: "raw", edited: "edited")

        let reader = CorrectionLearningManager(defaults: defaults)
        #expect(reader.allCorrections().count == 1)
        #expect(reader.allCorrections()[0].rawText == "raw")
    }

    @Test("Corrupted data falls back to empty")
    func corruptedFallback() {
        let suite = "com.susurrus.correction.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("not valid json!!!", forKey: "correctionPairs")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let mgr = CorrectionLearningManager(defaults: defaults)
        #expect(mgr.allCorrections().isEmpty)
    }
}
