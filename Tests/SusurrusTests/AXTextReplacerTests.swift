import Foundation
import Testing
@testable import SusurrusKit

@Suite("AXTextReplacer locate Tests")
struct AXTextReplacerLocateTests {

    @Test("Unique occurrence returns its range")
    func uniqueFound() {
        let range = AXTextReplacer.locateUnique("hello world", in: "say hello world today")
        #expect(range == NSRange(location: 4, length: 11))
    }

    @Test("Needle equal to haystack returns full range")
    func fullMatch() {
        let range = AXTextReplacer.locateUnique("abc", in: "abc")
        #expect(range == NSRange(location: 0, length: 3))
    }

    @Test("Absent needle returns nil")
    func absent() {
        #expect(AXTextReplacer.locateUnique("missing", in: "some other text") == nil)
    }

    @Test("Duplicate occurrences return nil — never guess")
    func duplicates() {
        #expect(AXTextReplacer.locateUnique("again", in: "again and again") == nil)
    }

    @Test("Empty needle returns nil")
    func emptyNeedle() {
        #expect(AXTextReplacer.locateUnique("", in: "anything") == nil)
    }

    @Test("Range is in UTF-16 units (AX coordinate space)")
    func utf16Offsets() {
        // "🎙️" is 3 UTF-16 units + a space = needle starts at 4.
        let haystack = "🎙️ dictated text"
        let range = AXTextReplacer.locateUnique("dictated text", in: haystack)
        #expect(range == NSRange(location: 4, length: 13))
        // Sanity: the range round-trips through NSString extraction.
        if let range {
            #expect((haystack as NSString).substring(with: range) == "dictated text")
        }
    }

    @Test("Overlapping occurrences count as duplicates")
    func overlapping() {
        #expect(AXTextReplacer.locateUnique("aa", in: "aaa") == nil)
    }
}

@Suite("PasteTracker Tests")
struct PasteTrackerTests {

    @Test("Set and read back a record; nil clears it")
    func roundTrip() {
        let tracker = PasteTracker()
        #expect(tracker.last() == nil)

        let record = PasteRecord(text: "hello", bundleIdentifier: "com.example.app", processIdentifier: 123)
        tracker.set(record)
        #expect(tracker.last() == record)

        tracker.set(nil)
        #expect(tracker.last() == nil)
    }

    @Test("updateText swaps text but only when the record is unchanged")
    func updateTextGuarded() {
        let tracker = PasteTracker()
        let original = PasteRecord(text: "helo", bundleIdentifier: "com.x", processIdentifier: 1)
        tracker.set(original)

        tracker.updateText(to: "hello", expecting: original)
        #expect(tracker.last()?.text == "hello")
        // pid/bundle preserved across the swap.
        #expect(tracker.last()?.processIdentifier == 1)

        // A newer dictation replaced the record — a stale update is ignored.
        let newer = PasteRecord(text: "different", bundleIdentifier: "com.y", processIdentifier: 2)
        tracker.set(newer)
        tracker.updateText(to: "should not apply", expecting: original)
        #expect(tracker.last() == newer)
    }
}

@Suite("AXTextReplacer outcome Tests")
struct AXTextReplacerOutcomeTests {

    @Test("Stale record is refused before any AX work")
    func staleRecordRefused() {
        // Staleness is the first, AX-independent guard, so this is
        // deterministic even in the untrusted test process.
        let old = PasteRecord(
            text: "hello",
            bundleIdentifier: "com.example",
            processIdentifier: 99999,
            pastedAt: Date().addingTimeInterval(-(AXTextReplacer.maxRecordAge + 60))
        )
        let outcome = AXTextReplacer().replaceLastPaste(record: old, with: "goodbye")
        #expect(outcome == .recordStale)
    }
}
