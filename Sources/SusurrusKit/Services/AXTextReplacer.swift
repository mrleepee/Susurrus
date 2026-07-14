import AppKit
import ApplicationServices

/// What Susurrus pasted, and where, captured at auto-paste time so the Fix
/// Last Dictation window can later replace it in place.
public struct PasteRecord: Sendable, Equatable {
    public let text: String
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let pastedAt: Date

    public init(
        text: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        pastedAt: Date = Date()
    ) {
        self.text = text
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.pastedAt = pastedAt
    }
}

/// Result of an in-place replacement attempt. Everything except `.replaced`
/// means the target application was left untouched.
public enum ReplaceOutcome: Sendable, Equatable {
    case replaced
    /// AXIsProcessTrusted() == false — Accessibility permission missing.
    case accessibilityDenied
    /// The recorded pid is gone or now belongs to a different bundle.
    case appNotRunning
    /// Couldn't get the app's focused UI element or read its string value.
    case focusedElementUnavailable
    /// The pasted text is no longer present verbatim (user edited it, or
    /// the app transformed it — smart quotes, autocorrect).
    case textNotFound
    /// The pasted text occurs more than once — refuse to guess which.
    case ambiguous
    /// Selection or text set failed, or the post-write verification did.
    case notWritable
}

/// Replaces previously-pasted text inside another application via the
/// Accessibility API (the TextExpander technique): select the exact range
/// with `kAXSelectedTextRangeAttribute`, then write over the selection with
/// `kAXSelectedTextAttribute`. Works without bringing the target app to the
/// front. Never guesses — any ambiguity or failure leaves the target alone.
public final class AXTextReplacer: @unchecked Sendable {

    public init() {}

    /// Locate `needle` in `haystack` and return its NSRange (UTF-16 units,
    /// the coordinate space AX text ranges use) only when it occurs exactly
    /// once. Pure logic, exposed for unit tests.
    public static func locateUnique(_ needle: String, in haystack: String) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let ns = haystack as NSString
        let first = ns.range(of: needle, options: .literal)
        guard first.location != NSNotFound else { return nil }

        // Search for a second occurrence starting one unit after the first
        // match's start (not after its end) so overlapping repeats — "aa"
        // in "aaa" — also count as ambiguous.
        let rest = NSRange(
            location: first.location + 1,
            length: ns.length - (first.location + 1)
        )
        let second = ns.range(of: needle, options: .literal, range: rest)
        guard second.location == NSNotFound else { return nil }

        return first
    }

    /// Replace the recorded paste with `replacement` inside the target app.
    /// Synchronous AX calls — run off the main thread if latency matters.
    public func replaceLastPaste(record: PasteRecord, with replacement: String) -> ReplaceOutcome {
        guard AXIsProcessTrusted() else { return .accessibilityDenied }

        guard let app = NSRunningApplication(processIdentifier: record.processIdentifier),
              record.bundleIdentifier == nil || app.bundleIdentifier == record.bundleIdentifier else {
            return .appNotRunning
        }

        let axApp = AXUIElementCreateApplication(record.processIdentifier)

        guard let focused = copyElement(axApp, kAXFocusedUIElementAttribute) else {
            return .focusedElementUnavailable
        }
        guard let value = copyString(focused, kAXValueAttribute) else {
            return .focusedElementUnavailable
        }

        guard let range = Self.locateUnique(record.text, in: value) else {
            return value.contains(record.text) ? .ambiguous : .textNotFound
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return .notWritable }
        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, axRange
        ) == .success else {
            return .notWritable
        }

        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, replacement as CFString
        ) == .success else {
            return .notWritable
        }

        // Best-effort verification: some apps report success without
        // applying the write; only claim victory if the text is there.
        guard let after = copyString(focused, kAXValueAttribute),
              after.contains(replacement) else {
            return .notWritable
        }
        return .replaced
    }

    // MARK: - AX plumbing

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return (ref as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}

/// Process-wide holder for the most recent auto-paste. Written by the
/// dictation-stop path, read by the Fix Last Dictation window. A new
/// dictation overwrites it; a successful in-place fix updates it so a
/// second fix of the same dictation still works.
public final class PasteTracker: @unchecked Sendable {
    public static let shared = PasteTracker()

    private let lock = NSLock()
    private var record: PasteRecord?

    public init() {}

    public func set(_ record: PasteRecord?) {
        lock.lock()
        defer { lock.unlock() }
        self.record = record
    }

    public func last() -> PasteRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }
}
