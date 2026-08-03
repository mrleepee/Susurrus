import Foundation
import Testing
@testable import Susurrus
@testable import SusurrusKit

@Suite("OverlayMessageService Tests")
struct OverlayMessageServiceTests {

    // MARK: - Composition

    @Test("Title and body join into one line")
    func joinsTitleAndBody() {
        let text = OverlayMessageService.compose(
            title: "Correction learned",
            body: "'ces' → 'CAS'"
        )
        #expect(text == "Correction learned — 'ces' → 'CAS'")
    }

    @Test("An empty body degrades to the title alone")
    func emptyBodyUsesTitle() {
        #expect(OverlayMessageService.compose(title: "Recording stopped", body: "") == "Recording stopped")
    }

    @Test("An empty title degrades to the body alone")
    func emptyTitleUsesBody() {
        #expect(OverlayMessageService.compose(title: "", body: "Nothing was transcribed.") == "Nothing was transcribed.")
    }

    @Test("A body that already restates the title is not doubled up")
    func doesNotRepeatTitle() {
        // Several call sites pass an error description that begins with the
        // same words as the title; "Recording failed — Recording failed: no
        // input device" reads badly in a one-line overlay.
        let text = OverlayMessageService.compose(
            title: "Recording failed",
            body: "Recording failed: no input device."
        )
        #expect(text == "Recording failed: no input device.")
    }

    @Test("Surrounding whitespace is trimmed before joining")
    func trimsWhitespace() {
        #expect(OverlayMessageService.compose(title: "  Title  ", body: "  Body  ") == "Title — Body")
    }

    @Test("Both halves empty yields an empty string rather than a stray dash")
    func bothEmpty() {
        #expect(OverlayMessageService.compose(title: "", body: "").isEmpty)
    }

    // MARK: - Duration

    @Test("A short message uses the floor, not less")
    func shortMessageClampsToMinimum() {
        let d = OverlayMessageService.duration(for: "Done")
        #expect(d == OverlayMessageService.minimumDuration)
    }

    @Test("A long message is capped, not left up indefinitely")
    func longMessageClampsToMaximum() {
        let d = OverlayMessageService.duration(for: String(repeating: "x", count: 5_000))
        #expect(d == OverlayMessageService.maximumDuration)
    }

    @Test("Duration scales with length between the bounds")
    func durationScales() {
        // The permission messages are the reason this scales at all: at the
        // overlay's fixed 1.8s they could not be read.
        let short = OverlayMessageService.duration(for: String(repeating: "x", count: 60))
        let long = OverlayMessageService.duration(for: String(repeating: "x", count: 110))
        #expect(long > short)
        #expect(short >= OverlayMessageService.minimumDuration)
        #expect(long <= OverlayMessageService.maximumDuration)
    }

    @Test("A real permission message gets more than the overlay's default")
    func permissionMessageGetsReadingTime() {
        let text = OverlayMessageService.compose(
            title: "Microphone access needed",
            body: "Enable Susurrus in System Settings → Privacy & Security → Microphone."
        )
        #expect(OverlayMessageService.duration(for: text) > OverlayMessageService.minimumDuration)
    }

    // MARK: - Protocol conformance

    @Test("Still satisfies Notifying, so call sites and their mocks are unchanged")
    func conformsToNotifying() {
        let service: any Notifying = OverlayMessageService.shared
        #expect(service is OverlayMessageService)
    }
}
