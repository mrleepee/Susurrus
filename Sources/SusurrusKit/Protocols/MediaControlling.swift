import Foundation

/// Protocol for pausing and resuming media playback from other applications.
public protocol MediaControlling: Sendable {
    /// Pauses all currently playing media apps and returns the list of app names that were paused.
    func pausePlayingApps() async -> [String]

    /// Resumes playback in the specified apps.
    func resumeApps(_ appNames: [String]) async
}
