import Foundation

/// Live-audio tests require a real microphone and a persistent Microphone TCC
/// grant, which the ad-hoc-signed test binary does not have. Under a plain
/// `swift test` they either fail (empty capture buffer) or hang indefinitely
/// (a live `AudioStreamTranscriber` waiting on an audio device that never
/// delivers samples).
///
/// They are therefore opt-in: set `SUSURRUS_LIVE_AUDIO_TESTS=1` and run against
/// an environment with a real mic (e.g. the stably-signed bundle from
/// `make bundle` after granting Microphone access once).
var liveAudioTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["SUSURRUS_LIVE_AUDIO_TESTS"] == "1"
}
