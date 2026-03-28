/// Protocol abstracting clipboard access for testability.
public protocol ClipboardManaging: Sendable {
    /// Write text to the clipboard, replacing the current contents.
    func writeText(_ text: String)

    /// Append text to existing clipboard content with a newline separator.
    /// If clipboard is empty, behaves like writeText.
    func appendText(_ text: String)

    /// Read the current clipboard text, if any.
    func readText() -> String?
}

/// Errors during clipboard operations.
public enum ClipboardError: Error, Sendable, Equatable {
    case writeFailed(String)
    case readFailed(String)
}
