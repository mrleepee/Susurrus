import Foundation
import SusurrusKit

// The deterministic noise source used by `synth`. Hand-rolled so the same
// seed gives the same bytes on every machine (no system RNG). WAV reading
// and writing lives in SusurrusKit (`WAV`), shared with the app's capture.

/// SplitMix64: tiny, fast, fully specified, so noise is reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1).
    mutating func unit() -> Double {
        (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992.0
    }

    /// Standard normal via Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = unit(), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// FNV-1a, for deriving a stable seed from a clip id.
func stableSeed(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

enum Noise {
    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// `samples` plus white Gaussian noise at `snrDB` below the signal RMS.
    static func mix(_ samples: [Float], snrDB: Double, seed: UInt64) -> [Float] {
        let sigma = rms(samples) / pow(10, snrDB / 20)
        var rng = SplitMix64(seed: seed)
        return samples.map { max(-1, min(1, $0 + Float(rng.gaussian() * sigma))) }
    }

    /// Quiet room noise (RMS about 0.008) that always peaks at or above
    /// `minPeak`, so it clears the decoder's 0.015 silence gate and the
    /// decoder actually runs on it — hallucination bait.
    static func room(seconds: Double, seed: UInt64, rms target: Double = 0.008, minPeak: Float = 0.035) -> [Float] {
        let count = max(1, Int(seconds * Double(WAV.sampleRate)))
        var rng = SplitMix64(seed: seed)
        var samples = (0..<count).map { _ in Float(rng.gaussian() * target) }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak < minPeak, peak > 0 {
            let scale = minPeak / peak
            samples = samples.map { $0 * scale }
        }
        return samples
    }
}
