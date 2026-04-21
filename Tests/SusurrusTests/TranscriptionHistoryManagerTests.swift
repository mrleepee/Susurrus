import Foundation
import Testing
@testable import SusurrusKit

@Suite("Transcription History Manager Tests")
struct TranscriptionHistoryManagerTests {

    private func makeManager() -> TranscriptionHistoryManager {
        TranscriptionHistoryManager.createForTesting()
    }

    @Test("Empty by default")
    func emptyByDefault() {
        let manager = makeManager()
        #expect(manager.items().isEmpty)
    }

    @Test("Add with text only has nil rawText")
    func addWithTextOnly() {
        let manager = makeManager()
        manager.add("hello world")
        let items = manager.items()
        #expect(items.count == 1)
        #expect(items[0].text == "hello world")
        #expect(items[0].rawText == nil)
    }

    @Test("Add with text and rawText stores both")
    func addWithTextAndRawText() {
        let manager = makeManager()
        manager.add("clean text", rawText: "raw ASR output")
        let items = manager.items()
        #expect(items.count == 1)
        #expect(items[0].text == "clean text")
        #expect(items[0].rawText == "raw ASR output")
    }

    @Test("Items returned newest first")
    func itemsReturnedNewestFirst() {
        let manager = makeManager()
        manager.add("first")
        manager.add("second")
        manager.add("third")
        let items = manager.items()
        #expect(items.count == 3)
        #expect(items[0].text == "third")
        #expect(items[1].text == "second")
        #expect(items[2].text == "first")
    }

    @Test("updateText changes text and preserves id and rawText")
    func updateTextChangesText() {
        let manager = makeManager()
        manager.add("original", rawText: "raw original")
        let original = manager.items()[0]
        let originalId = original.id

        manager.updateText(id: originalId, newText: "corrected")
        let updated = manager.items()[0]

        #expect(updated.id == originalId)
        #expect(updated.text == "corrected")
        #expect(updated.rawText == "raw original")
    }

    @Test("updateText with identical text does not duplicate or change item")
    func updateTextIdenticalNoOp() {
        let manager = makeManager()
        manager.add("same text")
        let original = manager.items()[0]
        manager.updateText(id: original.id, newText: "same text")
        #expect(manager.items().count == 1)
        #expect(manager.items()[0].text == "same text")
    }

    @Test("clear empties history")
    func clearEmptiesHistory() {
        let manager = makeManager()
        manager.add("one")
        manager.add("two")
        #expect(manager.items().count == 2)
        manager.clear()
        #expect(manager.items().isEmpty)
    }

    @Test("Adding beyond maxItems caps the list at 200")
    func addingBeyondMaxCapsList() {
        let manager = makeManager()
        for i in 0..<205 {
            manager.add("item \(i)")
        }
        let items = manager.items()
        #expect(items.count == TranscriptionHistoryManager.maxItems)
        // Newest should be "item 204", oldest kept should be "item 5"
        #expect(items.first?.text == "item 204")
        #expect(items.last?.text == "item 5")
    }

    @Test("updateText records correction when correctionManager is set")
    func updateTextRecordsCorrection() {
        let manager = makeManager()
        let mock = MockCorrectionLearning()
        manager.correctionManager = mock

        manager.add("raw ASR output", rawText: "raw asr output")
        let item = manager.items()[0]
        manager.updateText(id: item.id, newText: "corrected output")

        #expect(mock.recordedCorrections.count == 1)
        #expect(mock.recordedCorrections[0].raw == "raw asr output")
        #expect(mock.recordedCorrections[0].edited == "corrected output")
    }

    @Test("updateText records correction using original text when rawText is nil")
    func updateTextRecordsCorrectionWithoutRawText() {
        let manager = makeManager()
        let mock = MockCorrectionLearning()
        manager.correctionManager = mock

        manager.add("original text")
        let item = manager.items()[0]
        manager.updateText(id: item.id, newText: "edited text")

        #expect(mock.recordedCorrections.count == 1)
        #expect(mock.recordedCorrections[0].raw == "original text")
        #expect(mock.recordedCorrections[0].edited == "edited text")
    }

    @Test("updateText with unknown id does nothing")
    func updateTextUnknownId() {
        let manager = makeManager()
        manager.add("existing")
        manager.updateText(id: UUID(), newText: "ghost")
        #expect(manager.items().count == 1)
        #expect(manager.items()[0].text == "existing")
    }

    @Test("updateText does not record correction when raw equals new text")
    func updateTextNoCorrectionWhenRawMatchesNew() {
        let manager = makeManager()
        let mock = MockCorrectionLearning()
        manager.correctionManager = mock

        // rawText == newText scenario: add with rawText, then update to same as rawText
        manager.add("same", rawText: "same")
        let item = manager.items()[0]
        manager.updateText(id: item.id, newText: "same")

        // oldText == newText guard fires first, so no correction recorded
        #expect(mock.recordedCorrections.isEmpty)
    }

    @Test("Corrupted persisted JSON falls back to empty")
    func corruptedJsonFallback() {
        let suite = "com.susurrus.test.history.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Write garbage to the history key
        defaults.set("this is not valid json!!!", forKey: "transcriptionHistory")

        let manager = TranscriptionHistoryManager(defaults: defaults)
        #expect(manager.items().isEmpty)
    }

    @Test("withText preserves id, rawText, and date")
    func withTextPreservesMetadata() {
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let item = TranscriptionHistoryItem(text: "original", rawText: "orig raw", date: fixedDate)
        let updated = item.withText("new text")

        #expect(updated.id == item.id)
        #expect(updated.text == "new text")
        #expect(updated.rawText == "orig raw")
        #expect(updated.date == fixedDate)
    }

    @Test("History persists across manager instances")
    func crossInstancePersistence() {
        let suite = "com.susurrus.test.history.cross.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let writer = TranscriptionHistoryManager(defaults: defaults)
        writer.add("persistent text", rawText: "raw")

        let reader = TranscriptionHistoryManager(defaults: defaults)
        let items = reader.items()
        #expect(items.count == 1)
        #expect(items[0].text == "persistent text")
        #expect(items[0].rawText == "raw")
    }
}

// MARK: - Mock CorrectionLearning

private final class MockCorrectionLearning: CorrectionLearning, @unchecked Sendable {
    struct RecordedCorrection {
        let raw: String
        let edited: String
    }

    var recordedCorrections: [RecordedCorrection] = []

    func recordCorrection(raw: String, edited: String) {
        recordedCorrections.append(RecordedCorrection(raw: raw, edited: edited))
    }

    func relevantCorrections(for text: String, limit: Int) -> [CorrectionPair] { [] }
    func allCorrections() -> [CorrectionPair] { [] }
    func clearCorrections() { recordedCorrections.removeAll() }
    func fewShotString(for text: String, limit: Int) -> String { "" }
}
