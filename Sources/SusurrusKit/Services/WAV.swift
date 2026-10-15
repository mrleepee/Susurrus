import Foundation

/// A WAV file the reader can't use.
public struct WAVError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal 16 kHz mono PCM16 WAV reading/writing, shared by the eval
/// harness and the app's accuracy-testing capture. Hand-rolled so output
/// bytes are fully determined by the samples (no resampling, no metadata).
public enum WAV {
    public static let sampleRate = 16_000

    public static func write(samples: [Float], to url: URL) throws {
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
    public static func read(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard data.count >= 12, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw WAVError("\(url.lastPathComponent): not a RIFF/WAVE file")
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
                    throw WAVError("\(url.lastPathComponent): expected 16 kHz mono PCM16, got \(rate) Hz, \(channels) ch, \(bits)-bit")
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
        throw WAVError("\(url.lastPathComponent): no data chunk")
    }
}
