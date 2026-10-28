import Testing
@testable import SusurrusKit

@Suite("ParakeetTranscriber Tests")
struct ParakeetTranscriberTests {

    /// Samples whose value is their own index, so the output shows exactly
    /// which input samples were kept.
    private func ramp(_ n: Int) -> [Float] { ramp(0, n) }
    private func ramp(_ from: Int, _ to: Int) -> [Float] { (from..<to).map(Float.init) }

    @Test("A long pause keeps only `keep` samples of room tone at each side")
    func squeezesLongPause() {
        let out = ParakeetTranscriber.squeezePauses(ramp(100), speech: [(10, 20), (80, 90)], keep: 3)
        var expected = ramp(0, 3) + ramp(7, 10)   // lead-in squeezed
        expected += ramp(10, 20)                  // speech 1
        expected += ramp(20, 23) + ramp(77, 80)   // gap squeezed
        expected += ramp(80, 90)                  // speech 2
        expected += ramp(90, 93)                  // tail
        #expect(out == expected)
    }

    @Test("A short pause is kept whole")
    func keepsShortPause() {
        let out = ParakeetTranscriber.squeezePauses(ramp(30), speech: [(0, 10), (14, 24)], keep: 3)
        #expect(out == ramp(27))
    }

    @Test("No detected speech returns the buffer untouched")
    func noSpeechKeepsBuffer() {
        let samples = ramp(50)
        #expect(ParakeetTranscriber.squeezePauses(samples, speech: [], keep: 3) == samples)
    }

    @Test("Overlapping and out-of-range speech ranges are clamped, not duplicated")
    func clampsRanges() {
        let out = ParakeetTranscriber.squeezePauses(ramp(40), speech: [(0, 20), (15, 60)], keep: 3)
        #expect(out == ramp(40))
    }

    @Test("Only the picker id selects Parakeet")
    func pickerID() {
        #expect(ParakeetTranscriber.isParakeet("parakeet-v2"))
        #expect(!ParakeetTranscriber.isParakeet("small"))
        #expect(!ParakeetTranscriber.isParakeet("large-v3"))
    }
}
