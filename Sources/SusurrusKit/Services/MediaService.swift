import AppKit

/// Writes to ~/susurrus_debug.log — same sink as traceApp() in the app layer.
private func traceMedia(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [media] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

/// Controls media playback in other applications via AppleScript.
/// Pauses playing media when recording starts and resumes when recording stops.
///
/// Sending Apple Events to another app requires both
/// `NSAppleEventsUsageDescription` in Info.plist (else macOS denies silently
/// and never prompts) and a user Automation grant. Denials are traced, not
/// swallowed — this failed invisibly for months because nothing logged.
public final class MediaService: MediaControlling, @unchecked Sendable {

    /// Apple Event error raised when the Automation grant is missing/denied.
    private static let notPermittedError = -1743

    /// Media apps with AppleScript support for play/pause.
    private let knownApps: [(name: String, pauseScript: String, resumeScript: String)] = [
        ("Spotify", "pause", "play"),
        ("Music", "pause", "play"),
        ("VLC", "pause", "play"),
        ("QuickTime Player", "pause", "play"),
        ("iTunes", "pause", "play"),
    ]

    public init() {}

    /// Whether media should be paused, given the stored preference.
    /// Absent key means enabled — the Preferences toggle defaults to on, and
    /// `@AppStorage` doesn't write a value until the user changes it.
    static func shouldPause(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: "pauseMediaOnRecord") != nil else { return true }
        return defaults.bool(forKey: "pauseMediaOnRecord")
    }

    public func pausePlayingApps() async -> [String] {
        guard Self.shouldPause(defaults: .standard) else {
            traceMedia("pause skipped — preference off")
            return []
        }

        var paused: [String] = []
        for app in knownApps {
            // Cheap, permission-free liveness check first: asking System
            // Events instead would need its own Automation grant just to
            // learn the app isn't running.
            guard isRunning(app.name) else { continue }
            guard await isPlaying(app.name) else {
                traceMedia("\(app.name) running but not playing")
                continue
            }
            let result = await runAppleScript("tell application \"\(app.name)\" to \(app.pauseScript)")
            if result.denied {
                traceMedia("\(app.name) pause DENIED — grant Automation in System Settings > Privacy & Security > Automation")
                continue
            }
            traceMedia("paused \(app.name)")
            paused.append(app.name)
        }
        return paused
    }

    public func resumeApps(_ appNames: [String]) async {
        for appName in appNames {
            guard let app = knownApps.first(where: { $0.name == appName }) else { continue }
            let result = await runAppleScript("tell application \"\(app.name)\" to \(app.resumeScript)")
            traceMedia(result.denied ? "\(app.name) resume DENIED" : "resumed \(app.name)")
        }
    }

    // MARK: - Helpers

    /// Uses NSWorkspace rather than AppleScript — no Automation grant needed,
    /// and it can't be defeated by a missing System Events permission.
    private func isRunning(_ appName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == appName }
    }

    private func isPlaying(_ appName: String) async -> Bool {
        let script = """
        tell application "\(appName)"
            try
                return (player state is playing) as text
            on error
                return "false"
            end try
        end tell
        """
        let result = await runAppleScript(script)
        if result.denied {
            traceMedia("\(appName) player-state DENIED — Automation grant missing")
            return false
        }
        return result.value == "true"
    }

    private struct ScriptResult {
        let value: String?
        /// True when macOS refused the Apple Event (no Automation grant).
        let denied: Bool
    }

    /// Runs an AppleScript, distinguishing a permission denial from a plain
    /// failure so the caller can tell the user something actionable.
    private func runAppleScript(_ source: String) async -> ScriptResult {
        await Task.detached {
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
                let denied = (code == Self.notPermittedError)
                if !denied {
                    traceMedia("AppleScript error \(code): \(message)")
                }
                return ScriptResult(value: nil, denied: denied)
            }
            return ScriptResult(value: result?.stringValue, denied: false)
        }.value
    }
}
