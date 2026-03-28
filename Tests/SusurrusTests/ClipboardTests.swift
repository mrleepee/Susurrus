import Testing
@testable import SusurrusKit

/// Mock clipboard service for testing without NSPasteboard.
final class MockClipboardService: ClipboardManaging, @unchecked Sendable {
    var clipboardText: String?
    var writeCallCount = 0
    var lastWrittenText: String?

    func writeText(_ text: String) {
        writeCallCount += 1
        lastWrittenText = text
        clipboardText = text
    }

    func readText() -> String? {
        clipboardText
    }
}

@Suite("Clipboard Tests")
struct ClipboardTests {

    @Test("Write text stores in clipboard")
    func writeText() {
        let clipboard = MockClipboardService()
        clipboard.writeText("Hello, world!")
        #expect(clipboard.clipboardText == "Hello, world!")
    }

    @Test("Read text returns last written")
    func readText() {
        let clipboard = MockClipboardService()
        clipboard.writeText("Test")
        #expect(clipboard.readText() == "Test")
    }

    @Test("Read returns nil when nothing written")
    func readNilWhenEmpty() {
        let clipboard = MockClipboardService()
        #expect(clipboard.readText() == nil)
    }

    @Test("Write overwrites previous text")
    func overwriteText() {
        let clipboard = MockClipboardService()
        clipboard.writeText("First")
        clipboard.writeText("Second")
        #expect(clipboard.readText() == "Second")
    }

    @Test("Write tracks call count")
    func callCount() {
        let clipboard = MockClipboardService()
        clipboard.writeText("A")
        clipboard.writeText("B")
        #expect(clipboard.writeCallCount == 2)
    }

    @Test("Last written text is tracked")
    func lastWritten() {
        let clipboard = MockClipboardService()
        clipboard.writeText("A")
        clipboard.writeText("B")
        #expect(clipboard.lastWrittenText == "B")
    }

    @Test("ClipboardError equality")
    func errorEquality() {
        #expect(ClipboardError.writeFailed("a") == ClipboardError.writeFailed("a"))
        #expect(ClipboardError.writeFailed("a") != ClipboardError.writeFailed("b"))
        #expect(ClipboardError.readFailed("a") == ClipboardError.readFailed("a"))
    }
}
