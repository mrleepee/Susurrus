/// Protocol abstracting clipboard access for testability.
public protocol ClipboardManaging: Sendable {
    /// Write text to the clipboard, replacing the current contents.
    func writeText(_ text: String)

    /// Append text to existing clipboard content with a newline separator.
    /// If clipboard is empty, behaves like writeText.
    func appendText(_ text: String)

    /// Read the current clipboard text, if any.
    func readText() -> String?

    /// Simulate Cmd+V keystroke to paste clipboard contents at cursor.
    /// Returns true if the paste was sent, false if accessibility permissions are missing.
    @discardableResult
    func simulatePaste() -> Bool

    /// Paste into a known app, using the keystroke shape that app needs
    /// (see `PasteKeystroke`), and press Return after it when `pressReturn`
    /// (Go: send the message). Returns false if accessibility is missing.
    @discardableResult
    func simulatePaste(into bundleID: String?, pressReturn: Bool) -> Bool
}

public extension ClipboardManaging {
    @discardableResult
    func simulatePaste(into bundleID: String?, pressReturn: Bool) -> Bool { simulatePaste() }

    @discardableResult
    func simulatePaste(into bundleID: String?) -> Bool { simulatePaste(into: bundleID, pressReturn: false) }
}

/// One key event in a simulated paste.
public struct PasteKeystroke: Equatable, Sendable {
    public let keyCode: UInt16
    public let keyDown: Bool
    public let command: Bool
    /// Pause after posting, in microseconds.
    public let pauseAfter: UInt32

    static let vKey: UInt16 = 0x09
    static let commandKey: UInt16 = 0x37
    static let returnKey: UInt16 = 0x24

    /// Apps that track modifier keys from their own down/up events rather
    /// than the flags on each key event. Remote-desktop clients forward keys
    /// to another machine this way, so a bare ⌘-flagged V arrives as "v".
    /// Amazon WorkSpaces: a flagged V typed a literal "v" (2026-11).
    public static let explicitModifierApps: Set<String> = [
        "com.amazon.workspaces",
    ]

    /// The events for ⌘V into `bundleID`. Most apps get the long-standing
    /// flagged V down/up; apps in `explicitModifierApps` get the sequence a
    /// real keyboard produces — Command down, V down, V up, Command up —
    /// paced so the client forwards Command before V.
    ///
    /// With `pressReturn` (Go), a bare Return follows once the paste has
    /// landed. Remote clients get longer: the paste crosses the network
    /// before the Return does.
    public static func paste(into bundleID: String?, pressReturn: Bool = false) -> [PasteKeystroke] {
        let remote = bundleID.map(explicitModifierApps.contains) ?? false
        var strokes = pasteOnly(remote: remote)
        guard pressReturn else { return strokes }
        let last = strokes.removeLast()
        strokes.append(PasteKeystroke(keyCode: last.keyCode, keyDown: last.keyDown, command: last.command,
                                      pauseAfter: remote ? 250_000 : 100_000))
        strokes.append(PasteKeystroke(keyCode: returnKey, keyDown: true, command: false, pauseAfter: remote ? 50_000 : 20_000))
        strokes.append(PasteKeystroke(keyCode: returnKey, keyDown: false, command: false, pauseAfter: 0))
        return strokes
    }

    private static func pasteOnly(remote: Bool) -> [PasteKeystroke] {
        if remote {
            return [
                PasteKeystroke(keyCode: commandKey, keyDown: true, command: true, pauseAfter: 30_000),
                PasteKeystroke(keyCode: vKey, keyDown: true, command: true, pauseAfter: 50_000),
                PasteKeystroke(keyCode: vKey, keyDown: false, command: true, pauseAfter: 30_000),
                PasteKeystroke(keyCode: commandKey, keyDown: false, command: false, pauseAfter: 0),
            ]
        }
        return [
            PasteKeystroke(keyCode: vKey, keyDown: true, command: true, pauseAfter: 50_000),
            PasteKeystroke(keyCode: vKey, keyDown: false, command: true, pauseAfter: 0),
        ]
    }
}

/// Errors during clipboard operations.
public enum ClipboardError: Error, Sendable, Equatable {
    case writeFailed(String)
    case readFailed(String)
}
