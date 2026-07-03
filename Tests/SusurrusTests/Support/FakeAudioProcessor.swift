import AVFoundation
import CoreML
@preconcurrency import WhisperKit

/// Test-only AudioProcessing implementation that replays a pre-loaded float array as if
/// it were captured live from a microphone. Drives the same code paths as the real
/// AudioProcessor so integration tests exercise the full transcription pipeline.
///
/// Usage:
///   let fake = FakeAudioProcessor(samples: mySpeechSamples, sampleRate: 16_000)
///   try await service.startStreamTranscription(audioProcessorOverride: fake, callback: …)
final class FakeAudioProcessor: AudioProcessing, @unchecked Sendable {

    // MARK: - Config

    private let sourceSamples: [Float]
    private let chunkSize: Int          // frames per push (default 100ms @ 16kHz = 1600)
    private let pushIntervalNs: UInt64  // nanoseconds between chunk pushes

    // MARK: - Mutable state (protected by lock)

    private let stateLock = NSLock()
    private var _audioSamples = ContiguousArray<Float>()
    private var _relativeEnergy = [Float]()
    var relativeEnergyWindow: Int = 20

    private var replayTask: Task<Void, Never>?
    private var liveCallback: (([Float]) -> Void)?
    private var writeHead: Int = 0

    // MARK: - Spy state (read from tests to verify service behaviour)

    /// Number of samples in audioSamples at the moment startRecordingLive is called.
    /// -1 means startRecordingLive has not been called yet.
    /// Use this to assert that the service purged the buffer before recording began.
    private(set) var samplesAtRecordingStart: Int = -1

    /// Number of times purgeAudioSamples(keepingLast:) was called.
    private(set) var purgeCallCount: Int = 0

    /// The most recent `inputDeviceID` passed to `startRecordingLive` or
    /// `resumeRecordingLive`. Reads as `nil` before recording, or when the last
    /// caller requested the system default. Use to verify device routing.
    private(set) var lastRecordingDeviceID: DeviceID?

    // MARK: - Init

    /// - Parameters:
    ///   - samples: 16 kHz mono float audio to replay.
    ///   - chunkMs: Milliseconds of audio per push (default 100 ms).
    init(samples: [Float], chunkMs: Int = 100) {
        self.sourceSamples = samples
        self.chunkSize = 16_000 * chunkMs / 1_000
        self.pushIntervalNs = UInt64(chunkMs) * 1_000_000
    }

    // MARK: - AudioProcessing — live state

    var audioSamples: ContiguousArray<Float> {
        stateLock.withLock { _audioSamples }
    }

    var relativeEnergy: [Float] {
        stateLock.withLock { _relativeEnergy }
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        stateLock.withLock {
            purgeCallCount += 1
            guard keep < _audioSamples.count else { return }
            _audioSamples.removeFirst(_audioSamples.count - keep)
        }
    }

    /// Inject samples directly into the buffer without starting replay.
    /// Simulates residual audio left over from a previous session.
    func preloadSamples(_ samples: [Float]) {
        stateLock.withLock {
            _audioSamples.append(contentsOf: samples)
        }
    }

    // MARK: - AudioProcessing — recording lifecycle

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        stateLock.withLock {
            // Spy: capture how many samples existed before recording started.
            // If the service correctly called purgeAudioSamples(keepingLast:0)
            // before reaching here, this will be 0.
            samplesAtRecordingStart = _audioSamples.count
            lastRecordingDeviceID = inputDeviceID
            liveCallback = callback
            writeHead = 0
        }
        replayTask = Task { [weak self] in
            guard let self else { return }
            await self.replayLoop()
        }
    }

    func stopRecording() {
        replayTask?.cancel()
        replayTask = nil
        stateLock.withLock { liveCallback = nil }
    }

    func pauseRecording() {
        replayTask?.cancel()
        replayTask = nil
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        stateLock.withLock { lastRecordingDeviceID = inputDeviceID }
        try startRecordingLive(inputDeviceID: inputDeviceID, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?)
      -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - AudioProcessing — static pass-throughs

    static func loadAudio(
        fromPath audioFilePath: String,
        channelMode: ChannelMode,
        startTime: Double?,
        endTime: Double?,
        maxReadFrameSize: AVAudioFrameCount?
    ) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(
            fromPath: audioFilePath,
            channelMode: channelMode,
            startTime: startTime,
            endTime: endTime,
            maxReadFrameSize: maxReadFrameSize
        )
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode)
      async -> [Result<[Float], Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int,
        saveSegment: Bool
    ) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: saveSegment
        )
    }

    func padOrTrim(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int
    ) -> (any AudioProcessorOutputType)? {
        AudioProcessor().padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    // MARK: - Replay loop

    private func replayLoop() async {
        while !Task.isCancelled {
            let chunk: [Float]? = stateLock.withLock {
                let end = min(writeHead + chunkSize, sourceSamples.count)
                guard writeHead < end else { return nil }
                let slice = Array(sourceSamples[writeHead..<end])
                writeHead = end
                return slice
            }

            guard let chunk else { break }

            stateLock.withLock {
                _audioSamples.append(contentsOf: chunk)
                _relativeEnergy.append(Self.rmsEnergy(chunk))
                if _relativeEnergy.count > relativeEnergyWindow {
                    _relativeEnergy.removeFirst(_relativeEnergy.count - relativeEnergyWindow)
                }
            }

            let cb = stateLock.withLock { liveCallback }
            cb?(chunk)

            try? await Task.sleep(nanoseconds: pushIntervalNs)
        }
    }

    // MARK: - Helpers

    /// Generates a mono 16 kHz float array of a simple sine wave at the given frequency.
    /// Useful for creating test audio without real recordings.
    static func sineWave(hz: Float = 440, durationSeconds: Double, sampleRate: Int = 16_000) -> [Float] {
        let count = Int(Double(sampleRate) * durationSeconds)
        return (0..<count).map { i in
            0.3 * sin(2.0 * .pi * hz * Float(i) / Float(sampleRate))
        }
    }

    /// Generates a speech-like signal by mixing several harmonics (fundamental + overtones).
    /// More likely to pass WhisperKit's VAD threshold than a pure tone.
    static func speechLikeSignal(durationSeconds: Double, sampleRate: Int = 16_000) -> [Float] {
        let count = Int(Double(sampleRate) * durationSeconds)
        let fundamentals: [Float] = [150, 300, 600, 1200]
        return (0..<count).map { i in
            let t = Float(i) / Float(sampleRate)
            return fundamentals.reduce(0) { acc, f in
                acc + 0.1 * sin(2.0 * .pi * f * t)
            }
        }
    }

    private static func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }
}
