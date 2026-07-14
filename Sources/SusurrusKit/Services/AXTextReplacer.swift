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
    /// The record is older than the allowed window — the user has likely
    /// moved on, so we don't reach into a stale target.
    case recordStale
    /// Couldn't get the paste-target UI element or read its string value.
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

    /// Records older than this are refused — the fix flow is meant to run
    /// moments after a dictation, not minutes later against whatever now
    /// holds focus.
    public static let maxRecordAge: TimeInterval = 300

    public init() {}

    /// The focused UI element of the app with `pid`, captured so the caller
    /// can pin a replacement to the exact field that was pasted into rather
    /// than whatever holds focus at fix time. Returns nil without AX trust.
    public func focusedElement(ofPID pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        return copyElement(axApp, kAXFocusedUIElementAttribute)
    }

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
    ///
    /// `preferredElement` should be the focused element captured at paste
    /// time (via `focusedElement(ofPID:)`). When present, the replacement is
    /// pinned to that exact field, so focus drifting to another field — or
    /// another field coincidentally containing the same text — cannot be
    /// clobbered. When nil (element capture failed), we fall back to the
    /// app's current focused element, still guarded by the unique-match check.
    ///
    /// Synchronous AX calls — run off the main thread if latency matters.
    public func replaceLastPaste(
        record: PasteRecord,
        with replacement: String,
        preferredElement: AXUIElement? = nil
    ) -> ReplaceOutcome {
        // Cheapest, AX-independent guard first: don't reach into anything if
        // the user has clearly moved on since the paste.
        guard Date().timeIntervalSince(record.pastedAt) <= Self.maxRecordAge else {
            return .recordStale
        }

        guard AXIsProcessTrusted() else { return .accessibilityDenied }

        guard let app = NSRunningApplication(processIdentifier: record.processIdentifier),
              record.bundleIdentifier == nil || app.bundleIdentifier == record.bundleIdentifier else {
            return .appNotRunning
        }

        let element: AXUIElement
        if let preferredElement {
            element = preferredElement
        } else {
            let axApp = AXUIElementCreateApplication(record.processIdentifier)
            guard let focused = copyElement(axApp, kAXFocusedUIElementAttribute) else {
                return .focusedElementUnavailable
            }
            element = focused
        }

        guard let value = copyString(element, kAXValueAttribute) else {
            return .focusedElementUnavailable
        }

        guard let range = Self.locateUnique(record.text, in: value) else {
            return value.contains(record.text) ? .ambiguous : .textNotFound
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return .notWritable }
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axRange
        ) == .success else {
            return .notWritable
        }

        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, replacement as CFString
        ) == .success else {
            return .notWritable
        }

        // Verify against the specific range we wrote: re-read the value and
        // confirm the replacement now sits where the needle was. `contains`
        // alone can be fooled when the replacement text already appears
        // elsewhere in the field.
        guard let after = copyString(element, kAXValueAttribute) else { return .notWritable }
        let afterNS = after as NSString
        let expectedEnd = range.location + (replacement as NSString).length
        guard expectedEnd <= afterNS.length,
              afterNS.substring(with: NSRange(location: range.location, length: (replacement as NSString).length)) == replacement else {
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

/// Process-wide holder for the most recent auto-paste, plus the focused UI
/// element it landed in. Written by the dictation-stop path, read by the Fix
/// Last Dictation window. A new dictation overwrites it; a successful
/// in-place fix updates it so a second fix of the same dictation still works.
///
/// The element is a live AX reference (not `Sendable`), so it lives here in a
/// lock-guarded class rather than in the `Sendable` `PasteRecord`.
public final class PasteTracker: @unchecked Sendable {
    public static let shared = PasteTracker()

    private let lock = NSLock()
    private var record: PasteRecord?
    private var element: AXUIElement?

    public init() {}

    public func set(_ record: PasteRecord?, element: AXUIElement? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.record = record
        self.element = record == nil ? nil : element
    }

    public func last() -> PasteRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    /// The record and its captured paste-target element together, so a fix
    /// reads a consistent snapshot even if a new dictation lands mid-fix.
    public func snapshot() -> (record: PasteRecord, element: AXUIElement?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let record else { return nil }
        return (record, element)
    }

    /// After a successful in-place fix, swap the stored record's text so a
    /// second fix of the same dictation still matches — keeping the same
    /// captured element and only if the record hasn't been replaced by a
    /// newer dictation in the meantime (guarded by `expecting`).
    public func updateText(to newText: String, expecting previous: PasteRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = record, current == previous else { return }
        record = PasteRecord(
            text: newText,
            bundleIdentifier: current.bundleIdentifier,
            processIdentifier: current.processIdentifier,
            pastedAt: current.pastedAt
        )
    }
}
