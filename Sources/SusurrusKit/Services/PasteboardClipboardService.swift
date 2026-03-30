@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import os.log

/// Concrete clipboard service using NSPasteboard.
public final class PasteboardClipboardService: ClipboardManaging, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private static let logger = Logger(subsystem: "com.susurrus.app", category: "Clipboard")

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.logger.info("writeText: wrote \(text.count) chars to pasteboard")
    }

    public func appendText(_ text: String) {
        let existing = pasteboard.string(forType: .string) ?? ""
        let separator = existing.isEmpty ? "" : "\n"
        pasteboard.clearContents()
        pasteboard.setString(existing + separator + text, forType: .string)
        Self.logger.info("appendText: wrote \(text.count) chars to pasteboard")
    }

    public func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    /// Simulate Cmd+V keystroke to paste clipboard contents at cursor.
    /// Requires macOS Accessibility permissions (System Settings > Privacy & Security > Accessibility).
    /// Returns true if the event was posted, false if accessibility permissions are missing.
    @discardableResult
    public func simulatePaste() -> Bool {
        let trusted = AXIsProcessTrusted()
        Self.logger.info("simulatePaste: AXIsProcessTrusted = \(trusted)")
        guard trusted else {
            // Prompt the user to grant access
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Self.logger.error("simulatePaste: could not create CGEvents")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)
        Self.logger.info("simulatePaste: posted Cmd+V via cghidEventTap")
        return true
    }

    /// Check whether the app has Accessibility permissions.
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permissions (opens System Settings).
    public static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
