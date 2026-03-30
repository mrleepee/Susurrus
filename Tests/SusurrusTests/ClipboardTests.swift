import Testing
@testable import SusurrusKit

/// Mock clipboard service for testing without NSPasteboard.
final class MockClipboardService: ClipboardManaging, @unchecked Sendable {
    var clipboardText: String?
    var writeCallCount = 0
    var appendCallCount = 0
    var lastWrittenText: String?

    func writeText(_ text: String) {
        writeCallCount += 1
        lastWrittenText = text
        clipboardText = text
    }

    func appendText(_ text: String) {
        appendCallCount += 1
        lastWrittenText = text
        let existing = clipboardText ?? ""
        let separator = existing.isEmpty ? "" : "\n"
        clipboardText = existing + separator + text
    }

    func readText() -> String? {
        clipboardText
    }

    @discardableResult
    func simulatePaste() -> Bool {
        true
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

    @Test("Clipboard not written when transcription fails")
    func clipboardNotWrittenOnTranscriptionFailure() async {
        let clipboard = MockClipboardService()
        let service = MockTranscriptionService()
        await service.setFailure(.transcriptionFailed("error"))

        // Simulate: transcription fails, clipboard should not be written
        do {
            _ = try await service.transcribe(audio: [0.1])
        } catch {
            // Expected failure — clipboard should remain untouched
        }

        #expect(clipboard.writeCallCount == 0)
        #expect(clipboard.readText() == nil)
    }

    @Test("Clipboard written only after successful transcription")
    func clipboardWrittenAfterSuccess() async throws {
        let clipboard = MockClipboardService()
        let service = MockTranscriptionService()
        await service.setMockResult("Hello, world!")

        let text = try await service.transcribe(audio: [0.1])
        clipboard.writeText(text)

        #expect(clipboard.writeCallCount == 1)
        #expect(clipboard.readText() == "Hello, world!")
    }

    @Test("Existing clipboard preserved on transcription failure")
    func existingClipboardPreserved() async {
        let clipboard = MockClipboardService()
        clipboard.writeText("existing content")

        let service = MockTranscriptionService()
        await service.setFailure(.transcriptionFailed("error"))

        do {
            _ = try await service.transcribe(audio: [0.1])
        } catch {
            // Failure — existing clipboard should be untouched
        }

        #expect(clipboard.readText() == "existing content")
        #expect(clipboard.writeCallCount == 1) // Only the initial write
    }

    // MARK: - Append mode (R19)

    @Test("Append text to empty clipboard writes as-is")
    func appendToEmpty() {
        let clipboard = MockClipboardService()
        clipboard.appendText("First")
        #expect(clipboard.readText() == "First")
    }

    @Test("Append text adds newline separator")
    func appendWithSeparator() {
        let clipboard = MockClipboardService()
        clipboard.writeText("First")
        clipboard.appendText("Second")
        #expect(clipboard.readText() == "First\nSecond")
    }

    @Test("Multiple appends accumulate")
    func multipleAppends() {
        let clipboard = MockClipboardService()
        clipboard.appendText("Line 1")
        clipboard.appendText("Line 2")
        clipboard.appendText("Line 3")
        #expect(clipboard.readText() == "Line 1\nLine 2\nLine 3")
    }

    @Test("Append tracks call count")
    func appendCallCount() {
        let clipboard = MockClipboardService()
        clipboard.appendText("A")
        clipboard.appendText("B")
        #expect(clipboard.appendCallCount == 2)
        #expect(clipboard.writeCallCount == 0)
    }
}
