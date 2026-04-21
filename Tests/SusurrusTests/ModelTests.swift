import Foundation
import Testing
@testable import SusurrusKit

// MARK: - R1: VocabularyCategory

@Suite("VocabularyCategory Tests")
struct VocabularyCategoryTests {

    @Test("allCases contains 8 categories")
    func allCasesCount() {
        #expect(VocabularyCategory.allCases.count == 8)
    }

    @Test("displayName returns correct labels")
    func displayNames() {
        #expect(VocabularyCategory.person.displayName == "Person")
        #expect(VocabularyCategory.company.displayName == "Company")
        #expect(VocabularyCategory.place.displayName == "Place")
        #expect(VocabularyCategory.project.displayName == "Project")
        #expect(VocabularyCategory.product.displayName == "Product")
        #expect(VocabularyCategory.technical.displayName == "Technical")
        #expect(VocabularyCategory.acronym.displayName == "Acronym")
        #expect(VocabularyCategory.custom.displayName == "Custom")
    }

    @Test("systemImage returns non-empty SF Symbol names")
    func systemImages() {
        for cat in VocabularyCategory.allCases {
            #expect(!cat.systemImage.isEmpty, "\(cat) has empty systemImage")
        }
    }

    @Test("systemImage returns distinct symbols per category")
    func distinctSystemImages() {
        let images = VocabularyCategory.allCases.map(\.systemImage)
        #expect(Set(images).count == images.count, "Duplicate systemImage found")
    }

    @Test("llmInstruction returns non-empty strings")
    func llmInstructions() {
        for cat in VocabularyCategory.allCases {
            #expect(!cat.llmInstruction.isEmpty, "\(cat) has empty llmInstruction")
        }
    }

    @Test("llmInstruction contains category-specific guidance")
    func llmInstructionContent() {
        #expect(VocabularyCategory.person.llmInstruction.contains("capitalize"))
        #expect(VocabularyCategory.product.llmInstruction.contains("capitalize"))
        #expect(VocabularyCategory.technical.llmInstruction.contains("preserve"))
        #expect(VocabularyCategory.acronym.llmInstruction.contains("uppercase"))
    }

    @Test("Codable roundtrip preserves category")
    func codableRoundtrip() throws {
        for cat in VocabularyCategory.allCases {
            let data = try JSONEncoder().encode(cat)
            let decoded = try JSONDecoder().decode(VocabularyCategory.self, from: data)
            #expect(decoded == cat, "Roundtrip failed for \(cat)")
        }
    }
}

// MARK: - R2: VocabularyEntry

@Suite("VocabularyEntry Tests")
struct VocabularyEntryTests {

    @Test("Init with default category is custom")
    func defaultCategory() {
        let entry = VocabularyEntry(term: "Test")
        #expect(entry.term == "Test")
        #expect(entry.category == .custom)
    }

    @Test("Init with explicit category")
    func explicitCategory() {
        let entry = VocabularyEntry(term: "SPARQL", category: .technical)
        #expect(entry.category == .technical)
    }

    @Test("Init with explicit ID preserves it")
    func explicitId() {
        let id = UUID()
        let entry = VocabularyEntry(id: id, term: "Test")
        #expect(entry.id == id)
    }

    @Test("Init without ID generates unique IDs")
    func uniqueIds() {
        let a = VocabularyEntry(term: "A")
        let b = VocabularyEntry(term: "B")
        #expect(a.id != b.id)
    }

    @Test("Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let id = UUID()
        let entry = VocabularyEntry(id: id, term: "MarkLogic", category: .technical)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VocabularyEntry.self, from: data)
        #expect(decoded.id == id)
        #expect(decoded.term == "MarkLogic")
        #expect(decoded.category == .technical)
    }

    @Test("Equatable compares by all fields")
    func equatable() {
        let id = UUID()
        let a = VocabularyEntry(id: id, term: "Test", category: .person)
        let b = VocabularyEntry(id: id, term: "Test", category: .person)
        let c = VocabularyEntry(id: id, term: "Test", category: .place)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - R3: CorrectionPair

@Suite("CorrectionPair Tests")
struct CorrectionPairTests {

    @Test("Init stores properties")
    func initStoresProperties() {
        let pair = CorrectionPair(rawText: "hello world", editedText: "Hello World")
        #expect(pair.rawText == "hello world")
        #expect(pair.editedText == "Hello World")
    }

    @Test("Init with explicit ID and date")
    func explicitIdAndDate() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1700000000)
        let pair = CorrectionPair(id: id, rawText: "a", editedText: "b", date: date)
        #expect(pair.id == id)
        #expect(pair.date == date)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let pair = CorrectionPair(rawText: "raw", editedText: "edited")
        let data = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(CorrectionPair.self, from: data)
        #expect(decoded.rawText == "raw")
        #expect(decoded.editedText == "edited")
    }

    @Test("Equatable")
    func equatable() {
        let id = UUID()
        let a = CorrectionPair(id: id, rawText: "x", editedText: "y")
        let b = CorrectionPair(id: id, rawText: "x", editedText: "y")
        #expect(a == b)
    }
}

// MARK: - R4: InterimTranscript

@Suite("InterimTranscript Tests")
struct InterimTranscriptTests {

    @Test("fullText concatenates confirmed and unconfirmed")
    func fullTextJoins() {
        let t = InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)
        #expect(t.fullText == "Hello world")
    }

    @Test("fullText with empty confirmed returns unconfirmed")
    func fullTextEmptyConfirmed() {
        let t = InterimTranscript(confirmed: "", unconfirmed: "world", isFinal: false)
        #expect(t.fullText == "world")
    }

    @Test("fullText with empty unconfirmed returns confirmed")
    func fullTextEmptyUnconfirmed() {
        let t = InterimTranscript(confirmed: "Hello ", unconfirmed: "", isFinal: true)
        #expect(t.fullText == "Hello ")
    }

    @Test("fullText with both empty returns empty string")
    func fullTextBothEmpty() {
        let t = InterimTranscript(confirmed: "", unconfirmed: "", isFinal: false)
        #expect(t.fullText == "")
    }

    @Test("isFinal is stored correctly")
    func isFinal() {
        let a = InterimTranscript(confirmed: "", unconfirmed: "", isFinal: true)
        let b = InterimTranscript(confirmed: "", unconfirmed: "", isFinal: false)
        #expect(a.isFinal == true)
        #expect(b.isFinal == false)
    }

    @Test("Equatable")
    func equatable() {
        let a = InterimTranscript(confirmed: "x", unconfirmed: "y", isFinal: true)
        let b = InterimTranscript(confirmed: "x", unconfirmed: "y", isFinal: true)
        let c = InterimTranscript(confirmed: "x", unconfirmed: "y", isFinal: false)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - R5: RecordingMode

@Suite("RecordingMode Tests")
struct RecordingModeTests {

    @Test("allCases count is 2")
    func allCasesCount() {
        #expect(RecordingMode.allCases.count == 2)
    }

    @Test("Contains pushToTalk and toggle")
    func containsBoth() {
        #expect(RecordingMode.allCases.contains(.pushToTalk))
        #expect(RecordingMode.allCases.contains(.toggle))
    }

    @Test("rawValue strings are correct")
    func rawValues() {
        #expect(RecordingMode.pushToTalk.rawValue == "push-to-talk")
        #expect(RecordingMode.toggle.rawValue == "toggle")
    }

    @Test("Init from rawValue")
    func initFromRawValue() {
        #expect(RecordingMode(rawValue: "push-to-talk") == .pushToTalk)
        #expect(RecordingMode(rawValue: "toggle") == .toggle)
        #expect(RecordingMode(rawValue: "invalid") == nil)
    }

    @Test("Codable roundtrip")
    func codable() throws {
        for mode in RecordingMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RecordingMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}

// MARK: - R6: RecordingState

@Suite("RecordingState Tests")
struct RecordingStateTests {

    @Test("allCases count is 5")
    func allCasesCount() {
        #expect(RecordingState.allCases.count == 5)
    }

    @Test("Contains all expected states")
    func containsAll() {
        let expected: Set<RecordingState> = [.idle, .recording, .processing, .streaming, .finalizing]
        #expect(Set(RecordingState.allCases) == expected)
    }

    @Test("Equatable")
    func equatable() {
        #expect(RecordingState.idle == RecordingState.idle)
        #expect(RecordingState.idle != RecordingState.streaming)
    }
}

// R7: TranscriptionHistoryItem — covered by CorrectionLearningTests.swift
