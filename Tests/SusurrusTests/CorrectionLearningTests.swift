import Testing
@testable import SusurrusKit

@Suite("Correction Learning Tests")
struct CorrectionLearningTests {

    private func makeManager() -> CorrectionLearningManager {
        CorrectionLearningManager.createForTesting()
    }

    @Test("Record and retrieve correction")
    func recordAndRetrieve() {
        let manager = makeManager()
        manager.recordCorrection(raw: "so I think um", edited: "I think")
        let all = manager.allCorrections()
        #expect(all.count == 1)
        #expect(all[0].rawText == "so I think um")
        #expect(all[0].editedText == "I think")
    }

    @Test("Identical text is not recorded")
    func identicalNotRecorded() {
        let manager = makeManager()
        manager.recordCorrection(raw: "hello", edited: "hello")
        #expect(manager.allCorrections().isEmpty)
    }

    @Test("Relevance ranking by word overlap")
    func relevanceRanking() {
        let manager = makeManager()
        manager.recordCorrection(raw: "data bid is great", edited: "DataBid is great")
        manager.recordCorrection(raw: "the weather is nice", edited: "The weather is nice.")
        let results = manager.relevantCorrections(for: "data bid project", limit: 2)
        #expect(results.count == 2)
        // "data bid is great" shares more words with query
        #expect(results[0].rawText == "data bid is great")
    }

    @Test("Limit respected")
    func limitRespected() {
        let manager = makeManager()
        for i in 0..<10 {
            manager.recordCorrection(raw: "raw \(i)", edited: "edited \(i)")
        }
        let results = manager.relevantCorrections(for: "raw", limit: 3)
        #expect(results.count <= 3)
    }

    @Test("Few-shot string formatting")
    func fewShotStringFormatting() {
        let manager = makeManager()
        manager.recordCorrection(raw: "data bid sow", edited: "DataBid SOW")
        let str = manager.fewShotString(for: "data bid", limit: 1)
        #expect(str.contains("Raw:"))
        #expect(str.contains("data bid sow"))
        #expect(str.contains("Fixed:"))
        #expect(str.contains("DataBid SOW"))
    }

    @Test("Empty manager returns empty results")
    func emptyManager() {
        let manager = makeManager()
        #expect(manager.allCorrections().isEmpty)
        #expect(manager.fewShotString(for: "test", limit: 5) == "")
    }

    @Test("Clear removes all corrections")
    func clearRemovesAll() {
        let manager = makeManager()
        manager.recordCorrection(raw: "a", edited: "A")
        manager.recordCorrection(raw: "b", edited: "B")
        #expect(manager.allCorrections().count == 2)
        manager.clearCorrections()
        #expect(manager.allCorrections().isEmpty)
    }

    @Test("Max 50 pairs retained")
    func maxPairsRetained() {
        let manager = makeManager()
        for i in 0..<55 {
            manager.recordCorrection(raw: "raw \(i)", edited: "edited \(i)")
        }
        #expect(manager.allCorrections().count == 50)
    }
}

@Suite("Transcription History Item Tests")
struct TranscriptionHistoryItemTests {

    @Test("New item with rawText stores it")
    func newItemWithRawText() {
        let item = TranscriptionHistoryItem(text: "clean", rawText: "raw")
        #expect(item.text == "clean")
        #expect(item.rawText == "raw")
    }

    @Test("Item without rawText has nil")
    func itemWithoutRawText() {
        let item = TranscriptionHistoryItem(text: "hello")
        #expect(item.rawText == nil)
    }

    @Test("withText preserves id and rawText")
    func withTextPreservesFields() {
        let original = TranscriptionHistoryItem(text: "old", rawText: "raw")
        let updated = original.withText("new")
        #expect(updated.id == original.id)
        #expect(updated.text == "new")
        #expect(updated.rawText == original.rawText)
        #expect(updated.date == original.date)
    }
}
