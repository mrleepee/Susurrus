import Foundation

/// Minimal PCM16 WAV reading/writing, plus the deterministic noise source
/// used by `synth`. Hand-rolled so the same seed gives the same bytes on
/// every machine (no system RNG, no resampling).
enum WAV {
    static let sampleRate = 16_000

    static func write(samples: [Float], to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16((clamped * 32767).rounded())
            u16(UInt16(bitPattern: v))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a mono 16 kHz PCM16 WAV (walks chunks, so extra chunks are fine).
    static func read(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard data.count >= 12, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw ToolError("\(url.lastPathComponent): not a RIFF/WAVE file")
        }
        var offset = 12
        var channels = 0, rate = 0, bits = 0
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            var size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard channels == 1, rate == sampleRate, bits == 16 else {
                    throw ToolError("\(url.lastPathComponent): expected 16 kHz mono PCM16, got \(rate) Hz, \(channels) ch, \(bits)-bit")
                }
                size = min(size, data.count - body)  // say may leave the size field unset
                var out = [Float](); out.reserveCapacity(size / 2)
                var p = body
                while p + 1 < body + size {
                    out.append(Float(Int16(bitPattern: UInt16(u16(p)))) / 32768)
                    p += 2
                }
                return out
            }
            offset = body + size + (size & 1)
        }
        throw ToolError("\(url.lastPathComponent): no data chunk")
    }
}

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
