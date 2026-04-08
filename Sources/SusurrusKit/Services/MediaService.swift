import AppKit

/// Controls media playback in other applications via AppleScript.
/// Pauses playing media when recording starts and resumes when recording stops.
public final class MediaService: MediaControlling, @unchecked Sendable {

    /// Media apps with AppleScript support for play/pause.
    private let knownApps: [(name: String, pauseScript: String, resumeScript: String)] = [
        ("Spotify", "pause", "play"),
        ("Music", "pause", "play"),
        ("VLC", "pause", "play"),
        ("QuickTime Player", "pause", "play"),
        ("iTunes", "pause", "play"),
    ]

    public init() {}

    public func pausePlayingApps() async -> [String] {
        let preference = UserDefaults.standard.bool(forKey: "pauseMediaOnRecord")
        // Default is true if key not set
        guard preference || !UserDefaults.standard.object(forKey: "pauseMediaOnRecord").exists else {
            return []
        }
        // If key not set at all, default to enabled
        if UserDefaults.standard.object(forKey: "pauseMediaOnRecord") == nil {
            // Key not set, default enabled — continue
        } else if !preference {
            return []
        }

        var paused: [String] = []
        for app in knownApps {
            if await isRunning(app.name), await isPlaying(app.name) {
                await runAppleScript("tell application \"\(app.name)\" to \(app.pauseScript)")
                paused.append(app.name)
            }
        }
        return paused
    }

    public func resumeApps(_ appNames: [String]) async {
        for appName in appNames {
            guard let app = knownApps.first(where: { $0.name == appName }) else { continue }
            await runAppleScript("tell application \"\(app.name)\" to \(app.resumeScript)")
        }
    }

    // MARK: - AppleScript helpers

    private func isRunning(_ appName: String) async -> Bool {
        let result = await runAppleScript("tell application \"System Events\" to (name of processes) contains \"\(appName)\"")
        return result == "true"
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
        return result == "true"
    }

    /// Runs an AppleScript and returns the result as a string, or nil on failure.
    private func runAppleScript(_ source: String) async -> String? {
        await Task.detached {
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            let result = script?.executeAndReturnError(&errorInfo)
            if errorInfo != nil {
                return nil
            }
            return result?.stringValue
        }.value
    }
}

// Helper to check if UserDefaults key exists
private extension Optional {
    var exists: Bool { self != nil }
}
