import AppKit
import Foundation
import SusurrusKit

/// Writes to ~/susurrus_debug.log — same sink as traceApp().
private func traceMessage(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [notify] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

/// `Notifying` implementation that renders through the app's own overlay
/// window instead of `UNUserNotificationCenter`.
///
/// macOS has repeatedly delivered this app's notifications with no readable
/// content. Measured 2026-08-03: the app posts successfully — authorization
/// granted, `add()` returns no error — but `com.susurrus.app` has no entry at
/// all in `~/Library/Preferences/com.apple.ncprefs.plist`, so Notification
/// Center has nothing to render with. Two earlier attempts (2026-07-05,
/// 2026-07-15) fixed individual symptoms and the problem came back both times.
///
/// The overlay is our own window, so it always renders. The cost is that a
/// message is transient and only visible while the user is looking at their
/// screen — acceptable, since every message here is the immediate result of
/// something they just did.
///
/// Conforms to `Notifying` so the thirteen call sites, and their tests, are
/// unchanged.
final class OverlayMessageService: Notifying, @unchecked Sendable {

    /// Shortest a message stays up. Matches the overlay's own default.
    static let minimumDuration: TimeInterval = 1.8
    /// Longest — beyond this a transient overlay is the wrong medium.
    static let maximumDuration: TimeInterval = 5.0
    /// Characters per second of reading time. Deliberately slow: this is a
    /// glance at the corner of the screen, not focused reading.
    static let charactersPerSecond: Double = 25

    static let shared = OverlayMessageService()

    func showNotification(title: String, body: String) {
        let text = Self.compose(title: title, body: body)
        let duration = Self.duration(for: text)
        traceMessage("overlay message '\(text)' for \(String(format: "%.1f", duration))s")
        Task { @MainActor in
            StreamingOverlayWindow.shared.showMessage(text, duration: duration)
        }
    }

    /// Joins the two halves of a notification into the single line the overlay
    /// renders. The title alone is used when there is no body, and the body
    /// alone when it already restates the title — otherwise the overlay would
    /// show "Recording failed — Recording failed: …".
    static func compose(title: String, body: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return title }
        guard !title.isEmpty else { return body }
        if body.lowercased().hasPrefix(title.lowercased()) { return body }
        return "\(title) — \(body)"
    }

    /// Reading time for the composed text, clamped at both ends.
    static func duration(for text: String) -> TimeInterval {
        let estimated = Double(text.count) / charactersPerSecond
        return Swift.min(Swift.max(estimated, minimumDuration), maximumDuration)
    }
}
