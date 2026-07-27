import Foundation
import Testing
@testable import SusurrusKit

/// Mock media service for testing without AppleScript.
final class MockMediaService: MediaControlling, @unchecked Sendable {
    var pausedApps: [String] = []
    var resumedApps: [String] = []
    var shouldPause: [String] = []  // apps that are "playing"

    func pausePlayingApps() async -> [String] {
        let toPause = shouldPause
        pausedApps.append(contentsOf: toPause)
        return toPause
    }

    func resumeApps(_ appNames: [String]) async {
        resumedApps.append(contentsOf: appNames)
    }
}

@Suite("MediaControlling Protocol Tests")
struct MediaServiceTests {

    @Test("Mock pausePlayingApps returns playing apps")
    func pauseReturnsPlaying() async {
        let mock = MockMediaService()
        mock.shouldPause = ["Spotify", "Music"]
        let result = await mock.pausePlayingApps()
        #expect(result == ["Spotify", "Music"])
    }

    @Test("Mock resumeApps records resumed apps")
    func resumeRecordsApps() async {
        let mock = MockMediaService()
        await mock.resumeApps(["Spotify"])
        #expect(mock.resumedApps == ["Spotify"])
    }

    @Test("Pause and resume roundtrip")
    func pauseResumeRoundtrip() async {
        let mock = MockMediaService()
        mock.shouldPause = ["Spotify", "VLC"]
        let paused = await mock.pausePlayingApps()
        await mock.resumeApps(paused)
        #expect(mock.resumedApps == ["Spotify", "VLC"])
    }

    @Test("No media playing returns empty list")
    func noMediaPlaying() async {
        let mock = MockMediaService()
        let result = await mock.pausePlayingApps()
        #expect(result.isEmpty)
    }

    @Test("Resume empty list is safe")
    func resumeEmptyList() async {
        let mock = MockMediaService()
        await mock.resumeApps([])
        #expect(mock.resumedApps.isEmpty)
    }

    @Test("Multiple pause/resume cycles accumulate")
    func multipleCycles() async {
        let mock = MockMediaService()
        mock.shouldPause = ["Spotify"]
        _ = await mock.pausePlayingApps()
        mock.shouldPause = ["Music"]
        _ = await mock.pausePlayingApps()
        await mock.resumeApps(mock.pausedApps)
        #expect(mock.pausedApps == ["Spotify", "Music"])
        #expect(mock.resumedApps == ["Spotify", "Music"])
    }
}

/// Covers the real `MediaService`'s preference gate. Previously only the
/// mock was tested, so nothing verified the actual service — the reason a
/// broken pause shipped unnoticed. The AppleScript paths need a live app
/// plus an Automation grant, so they stay manual; this pins the pure logic.
@Suite("MediaService preference gate Tests")
struct MediaServicePreferenceTests {

    private func defaults(_ suite: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: "com.susurrus.media.test.\(suite)")!
    }

    @Test("Absent key defaults to enabled")
    func absentKeyEnabled() {
        // @AppStorage doesn't persist until the user toggles it, so a fresh
        // install has no key — pausing must still be on, matching the
        // Preferences toggle's `= true` default.
        let d = defaults()
        #expect(d.object(forKey: "pauseMediaOnRecord") == nil)
        #expect(MediaService.shouldPause(defaults: d))
    }

    @Test("Explicit true enables")
    func explicitTrue() {
        let d = defaults()
        d.set(true, forKey: "pauseMediaOnRecord")
        #expect(MediaService.shouldPause(defaults: d))
    }

    @Test("Explicit false disables")
    func explicitFalse() {
        let d = defaults()
        d.set(false, forKey: "pauseMediaOnRecord")
        #expect(!MediaService.shouldPause(defaults: d))
    }

    @Test("Toggling off then on re-enables")
    func toggleRoundTrip() {
        let d = defaults()
        d.set(false, forKey: "pauseMediaOnRecord")
        #expect(!MediaService.shouldPause(defaults: d))
        d.set(true, forKey: "pauseMediaOnRecord")
        #expect(MediaService.shouldPause(defaults: d))
    }
}
