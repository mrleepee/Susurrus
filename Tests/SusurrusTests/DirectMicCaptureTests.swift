import CoreAudio
import Foundation
import Testing
@testable import SusurrusKit

@Suite("DirectMicCapture")
struct DirectMicCaptureTests {

    private func sine(rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
    }

    @Test("48 kHz input is resampled to 16 kHz, keeping its level")
    func resamplesTo16k() {
        let capture = DirectMicCapture(deviceID: 0) { _ in }
        capture.prepareForTesting(sampleRate: 48_000)
        let out = capture.process(nativeChunk: sine(rate: 48_000, seconds: 0.5))
        #expect(abs(out.count - 8_000) <= 64, "0.5 s at 16 kHz is ~8000 samples (got \(out.count))")
        let peak = out.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6, "level should survive resampling (peak \(peak))")
    }

    @Test("16 kHz input passes through unchanged")
    func passesThrough16k() {
        let capture = DirectMicCapture(deviceID: 0) { _ in }
        capture.prepareForTesting(sampleRate: 16_000)
        let input = sine(rate: 16_000, seconds: 0.1)
        #expect(capture.process(nativeChunk: input) == input)
    }

    /// Opt-in: records 2 s from the built-in mic. Needs a microphone and mic
    /// permission for the test host, so it only runs with
    /// `SUSURRUS_HARDWARE_TESTS=1 swift test --filter DirectMicCapture`.
    @Test(
        "built-in mic delivers frames even with a Bluetooth output",
        .enabled(if: ProcessInfo.processInfo.environment["SUSURRUS_HARDWARE_TESTS"] == "1")
    )
    func builtInMicDeliversFrames() throws {
        let service = AudioDeviceService()
        let builtIn = try #require(service.dictationInput(), "no Studio Display or built-in mic")
        let lock = NSLock()
        var received = 0
        let capture = DirectMicCapture(deviceID: builtIn.id) { samples in
            lock.lock(); received += samples.count; lock.unlock()
        }
        try capture.start()
        Thread.sleep(forTimeInterval: 2)
        capture.stop()
        lock.lock(); let total = received; lock.unlock()
        #expect(total > 16_000 * 3 / 2, "expected ~2 s of 16 kHz audio from '\(builtIn.name)', got \(total) samples")
    }
}
