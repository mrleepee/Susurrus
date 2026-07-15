import AppKit
import ApplicationServices

/// Writes to ~/susurrus_debug.log — same sink as traceApp() in the app layer.
private func traceAX(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [ax] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

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
    ///
    /// Chromium/Electron apps (Teams, Slack, VS Code) build their AX tree
    /// lazily and report no focused element until `AXManualAccessibility`
    /// is switched on — production logs showed element=false for every
    /// capture in Teams and Slack. We enable it, then retry once after a
    /// short pause for the tree to build.
    public func focusedElement(ofPID pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            traceAX("focusedElement: not trusted")
            return nil
        }
        let axApp = AXUIElementCreateApplication(pid)
        enableManualAccessibility(axApp, pid: pid)

        let (element, err) = copyElement(axApp, kAXFocusedUIElementAttribute)
        if let element {
            traceAX("focusedElement: app-level hit pid=\(pid)")
            return element
        }
        traceAX("focusedElement: app-level miss pid=\(pid) axErr=\(err.rawValue), retrying after tree build")

        // Give a freshly-enabled Chromium tree a moment, then retry.
        Thread.sleep(forTimeInterval: 0.3)
        let (retried, retryErr) = copyElement(axApp, kAXFocusedUIElementAttribute)
        if let retried {
            traceAX("focusedElement: app-level hit on retry pid=\(pid)")
            return retried
        }

        // Last resort: the system-wide focused element, accepted only when
        // it belongs to the target pid.
        let systemWide = AXUIElementCreateSystemWide()
        let (sysFocused, sysErr) = copyElement(systemWide, kAXFocusedUIElementAttribute)
        if let sysFocused {
            var elementPid: pid_t = 0
            if AXUIElementGetPid(sysFocused, &elementPid) == .success, elementPid == pid {
                traceAX("focusedElement: system-wide hit pid=\(pid)")
                return sysFocused
            }
            traceAX("focusedElement: system-wide element belongs to pid=\(elementPid), wanted \(pid)")
            return nil
        }
        traceAX("focusedElement: all paths failed pid=\(pid) retryErr=\(retryErr.rawValue) sysErr=\(sysErr.rawValue)")
        return nil
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
        } else if let focused = focusedElement(ofPID: record.processIdentifier) {
            element = focused
        } else {
            return .focusedElementUnavailable
        }

        let (value, valueErr) = copyString(element, kAXValueAttribute)
        guard let value else {
            traceAX("replace: value read failed axErr=\(valueErr.rawValue)")
            return .focusedElementUnavailable
        }

        guard let range = Self.locateUnique(record.text, in: value) else {
            traceAX("replace: needle \(value.contains(record.text) ? "ambiguous" : "not found") in \(value.count)-char value")
            return value.contains(record.text) ? .ambiguous : .textNotFound
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return .notWritable }
        let selectErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, axRange
        )
        guard selectErr == .success else {
            traceAX("replace: selection set failed axErr=\(selectErr.rawValue)")
            return .notWritable
        }

        let writeErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, replacement as CFString
        )
        guard writeErr == .success else {
            traceAX("replace: text set failed axErr=\(writeErr.rawValue)")
            return .notWritable
        }

        // Verify against the specific range we wrote: re-read the value and
        // confirm the replacement now sits where the needle was. `contains`
        // alone can be fooled when the replacement text already appears
        // elsewhere in the field.
        let (after, afterErr) = copyString(element, kAXValueAttribute)
        guard let after else {
            traceAX("replace: verification read failed axErr=\(afterErr.rawValue)")
            return .notWritable
        }
        let afterNS = after as NSString
        let replacementLength = (replacement as NSString).length
        let expectedEnd = range.location + replacementLength
        guard expectedEnd <= afterNS.length,
              afterNS.substring(with: NSRange(location: range.location, length: replacementLength)) == replacement else {
            traceAX("replace: verification mismatch at range \(range.location)+\(replacementLength)")
            return .notWritable
        }
        traceAX("replace: success in \(record.bundleIdentifier ?? "?")")
        return .replaced
    }

    // MARK: - AX plumbing

    /// Chromium-based apps expose their web-content AX tree only when an
    /// assistive client announces itself. `AXManualAccessibility` is the
    /// Electron-specific switch (Slack honours it); plain Chromium/WebView2
    /// apps (new Teams, Chrome, Edge) instead watch `AXEnhancedUserInterface`
    /// — the flag VoiceOver sets. Try both; native apps ignore or reject
    /// them harmlessly.
    private func enableManualAccessibility(_ axApp: AXUIElement, pid: pid_t) {
        let manualErr = AXUIElementSetAttributeValue(
            axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        if manualErr == .success { return }

        let enhancedErr = AXUIElementSetAttributeValue(
            axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        traceAX("enableAX pid=\(pid): manual axErr=\(manualErr.rawValue), enhanced axErr=\(enhancedErr.rawValue)")
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> (AXUIElement?, AXError) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return (nil, err)
        }
        return ((ref as! AXUIElement), err)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> (String?, AXError) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return (nil, err) }
        return (ref as? String, err)
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
