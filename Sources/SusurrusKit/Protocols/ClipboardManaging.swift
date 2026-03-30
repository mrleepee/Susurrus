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
}

/// Errors during clipboard operations.
public enum ClipboardError: Error, Sendable, Equatable {
    case writeFailed(String)
    case readFailed(String)
}
