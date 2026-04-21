import AppKit
import Foundation
import Testing
@testable import SusurrusKit

@Suite("PasteboardClipboardService Tests")
struct PasteboardClipboardServiceTests {

    // Use a fresh pasteboard for each test to avoid polluting the system clipboard
    private func makeService() -> (PasteboardClipboardService, NSPasteboard) {
        let pb = NSPasteboard.withUniqueName()
        let service = PasteboardClipboardService(pasteboard: pb)
        return (service, pb)
    }

    @Test("writeText sets clipboard content")
    func writeText() {
        let (service, pb) = makeService()
        service.writeText("hello")
        #expect(pb.string(forType: .string) == "hello")
    }

    @Test("writeText replaces previous content")
    func writeTextReplaces() {
        let (service, pb) = makeService()
        service.writeText("first")
        service.writeText("second")
        #expect(pb.string(forType: .string) == "second")
    }

    @Test("writeText handles empty string")
    func writeTextEmpty() {
        let (service, pb) = makeService()
        service.writeText("")
        #expect(pb.string(forType: .string) == "")
    }

    @Test("writeText handles unicode")
    func writeTextUnicode() {
        let (service, pb) = makeService()
        service.writeText("日本語テスト 🎵")
        #expect(pb.string(forType: .string) == "日本語テスト 🎵")
    }

    @Test("appendText adds to existing content with newline separator")
    func appendText() {
        let (service, pb) = makeService()
        service.writeText("hello")
        service.appendText("world")
        #expect(pb.string(forType: .string) == "hello\nworld")
    }

    @Test("appendText when clipboard is empty writes text without leading newline")
    func appendTextToEmpty() {
        let (service, pb) = makeService()
        service.appendText("hello")
        #expect(pb.string(forType: .string) == "hello")
    }

    @Test("readText returns clipboard content")
    func readText() {
        let (service, pb) = makeService()
        pb.setString("test content", forType: .string)
        #expect(service.readText() == "test content")
    }

    @Test("readText returns nil when clipboard empty")
    func readTextEmpty() {
        let (service, _) = makeService()
        #expect(service.readText() == nil || service.readText() == "")
    }

    @Test("write then read roundtrip")
    func writeReadRoundtrip() {
        let (service, _) = makeService()
        service.writeText("roundtrip test")
        #expect(service.readText() == "roundtrip test")
    }

    @Test("appendText multiple appends")
    func multipleAppends() {
        let (service, _) = makeService()
        service.writeText("a")
        service.appendText("b")
        service.appendText("c")
        #expect(service.readText() == "a\nb\nc")
    }

    @Test("isAccessibilityTrusted does not crash")
    func isAccessibilityTrustedNoCrash() {
        // Just verify it doesn't crash — result depends on system settings
        _ = PasteboardClipboardService.isAccessibilityTrusted()
    }
}
