import Testing
@testable import SusurrusKit

/// A mic delivering digital silence (stuck coreaudiod, 2026-11-27) must be
/// told apart from a quiet room, which always has some noise.
@Suite("Microphone silence")
struct MicSilenceTests {

    @Test("All-zero audio is dead")
    func zerosAreDead() {
        let samples = [Float](repeating: 0, count: 24_000)
        #expect(MicSilence.isDead(peak: MicSilence.peak(of: samples)))
    }

    @Test("The -91 dB a stuck mic produced counts as dead")
    func stuckMicLevelIsDead() {
        // -91 dBFS ≈ 2.8e-5, what ffmpeg measured from the stuck mic.
        #expect(MicSilence.isDead(peak: 0.000028))
    }

    @Test("A quiet room's noise floor is not dead", arguments: [
        Float(0.001),   // -60 dBFS
        Float(0.0003),  // -70 dBFS
    ])
    func quietRoomIsAlive(peak: Float) {
        #expect(!MicSilence.isDead(peak: peak))
    }

    @Test("Peak uses magnitude, so negative samples count")
    func peakUsesMagnitude() {
        #expect(MicSilence.peak(of: [0, -0.5, 0.2]) == 0.5)
    }

    @Test("No session, no peak to judge")
    func noSessionNoPeak() async {
        let service = StreamingTranscriptionService()
        #expect(await service.recentPeak(seconds: MicSilence.window) == nil)
    }
}
