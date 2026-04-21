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
