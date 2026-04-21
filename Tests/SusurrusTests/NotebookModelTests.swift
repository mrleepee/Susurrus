import Foundation
import Testing
@testable import SusurrusKit

@Suite("Notebook Model Tests")
struct NotebookModelTests {

    @Test("Init generates unique IDs")
    func uniqueIds() {
        let a = Notebook(name: "A")
        let b = Notebook(name: "B")
        #expect(a.id != b.id)
    }

    @Test("Init with explicit ID preserves it")
    func explicitId() {
        let id = UUID()
        let nb = Notebook(id: id, name: "Test")
        #expect(nb.id == id)
    }

    @Test("Init starts with empty entries")
    func emptyEntries() {
        let nb = Notebook(name: "Test")
        #expect(nb.entries.isEmpty)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let nb = Notebook(name: "Test")
        let data = try JSONEncoder().encode(nb)
        let decoded = try JSONDecoder().decode(Notebook.self, from: data)
        #expect(decoded.id == nb.id)
        #expect(decoded.name == "Test")
    }

    @Test("Different IDs not equal")
    func differentIdsNotEqual() {
        let a = Notebook(name: "X")
        let b = Notebook(name: "X")
        #expect(a != b) // Different UUIDs
    }

    @Test("Same name but different IDs are not equal")
    func sameNameDifferentIds() {
        let a = Notebook(name: "A")
        let b = Notebook(name: "A")
        #expect(a != b)
    }
}

@Suite("NotebookEntry Model Tests")
struct NotebookEntryModelTests {

    @Test("Init generates unique IDs")
    func uniqueIds() {
        let a = NotebookEntry(text: "a")
        let b = NotebookEntry(text: "b")
        #expect(a.id != b.id)
    }

    @Test("Init with explicit ID and date")
    func explicitIdAndDate() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1700000000)
        let entry = NotebookEntry(id: id, text: "test", date: date)
        #expect(entry.id == id)
        #expect(entry.date == date)
    }

    @Test("originalText defaults to nil")
    func originalTextDefaultNil() {
        let entry = NotebookEntry(text: "hello")
        #expect(entry.originalText == nil)
    }

    @Test("isEdited returns false when no originalText")
    func notEditedByDefault() {
        let entry = NotebookEntry(text: "hello")
        #expect(entry.isEdited == false)
    }

    @Test("isEdited returns true when originalText is set")
    func editedWhenOriginalTextSet() {
        let entry = NotebookEntry(text: "edited", originalText: "original")
        #expect(entry.isEdited == true)
    }

    @Test("diffDescription returns nil when no originalText")
    func diffDescriptionNil() {
        let entry = NotebookEntry(text: "hello")
        #expect(entry.diffDescription == nil)
    }

    @Test("diffDescription returns formatted diff")
    func diffDescriptionFormat() {
        let entry = NotebookEntry(text: "DataBid", originalText: "data bid")
        #expect(entry.diffDescription == "{data bid → DataBid}")
    }

    @Test("diffDescription returns nil when original matches text")
    func diffDescriptionNilWhenSame() {
        let entry = NotebookEntry(text: "same", originalText: "same")
        #expect(entry.diffDescription == nil)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let entry = NotebookEntry(text: "hello", originalText: "helo", editedDate: Date())
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(NotebookEntry.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.text == "hello")
        #expect(decoded.originalText == "helo")
        #expect(decoded.editedDate != nil)
    }

    @Test("sortedDescending sorts by date descending")
    func sortedDescending() {
        let old = NotebookEntry(text: "old", date: Date(timeIntervalSince1970: 1000))
        let mid = NotebookEntry(text: "mid", date: Date(timeIntervalSince1970: 2000))
        let new = NotebookEntry(text: "new", date: Date(timeIntervalSince1970: 3000))
        let sorted = NotebookEntry.sortedDescending([old, new, mid])
        #expect(sorted[0].text == "new")
        #expect(sorted[1].text == "mid")
        #expect(sorted[2].text == "old")
    }

    @Test("Equatable compares by id and content")
    func equatable() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = NotebookEntry(id: id, text: "x", originalText: "y", date: date)
        let b = NotebookEntry(id: id, text: "x", originalText: "y", date: date)
        #expect(a == b)
    }
}
