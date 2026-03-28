import AppKit

/// Concrete clipboard service using NSPasteboard.
public final class PasteboardClipboardService: ClipboardManaging, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func appendText(_ text: String) {
        let existing = pasteboard.string(forType: .string) ?? ""
        let separator = existing.isEmpty ? "" : "\n"
        pasteboard.clearContents()
        pasteboard.setString(existing + separator + text, forType: .string)
    }

    public func readText() -> String? {
        pasteboard.string(forType: .string)
    }
}
