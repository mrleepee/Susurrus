import Darwin
import Foundation

/// Single-keystroke input for the interactive commands (`review`, `record`).
///
/// On a terminal, reads one key without waiting for Return. When stdin is
/// not a terminal (a pipe in a test script), reads one byte at a time, so
/// `printf 'aes' | susurrus-eval review …` drives the same code path.
enum Terminal {
    nonisolated(unsafe) private static var saved = termios()
    nonisolated(unsafe) private static var rawActive = false

    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }
    static var colors: Bool { isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil }

    /// Restores the terminal if a signal arrives mid-read, so Ctrl-C never
    /// leaves the shell without echo.
    static func installSignalHandlers() {
        signal(SIGINT) { sig in
            Terminal.restore()
            signal(sig, SIG_DFL)
            raise(sig)
        }
    }

    /// The next key, or nil at end of input.
    static func readKey() -> Character? {
        if isInteractive {
            var raw = termios()
            tcgetattr(STDIN_FILENO, &saved)
            raw = saved
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            rawActive = true
        }
        defer { restore() }
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        guard n == 1 else { return nil }
        return Character(Unicode.Scalar(byte))
    }

    /// Reads keys until one of `allowed` (lowercased) arrives. Returns nil
    /// at end of input. Unlisted keys (including a pipe's newlines) are ignored.
    static func choose(_ allowed: Set<Character>) -> Character? {
        while let key = readKey() {
            let lower = Character(key.lowercased())
            if allowed.contains(lower) { return lower }
        }
        return nil
    }

    static func isEnter(_ key: Character) -> Bool { key == "\n" || key == "\r" }

    static func restore() {
        guard rawActive else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        rawActive = false
    }

    // MARK: - Styling

    static func bold(_ s: String) -> String { colors ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { colors ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    static func red(_ s: String) -> String { colors ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
    static func green(_ s: String) -> String { colors ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    static func yellow(_ s: String) -> String { colors ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
}

/// Plays a clip with `afplay` in the background; `stop()` cuts it off.
final class ClipPlayer {
    private var process: Process?
    let enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    func play(_ url: URL) {
        stop()
        guard enabled else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
        } catch {
            printErr("note: afplay failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
}
