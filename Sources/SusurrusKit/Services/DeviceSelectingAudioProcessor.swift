import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// An `AudioProcessing` wrapper that injects a preferred Core Audio device ID into
/// `startRecordingLive` and `resumeRecordingLive`. WhisperKit's `AudioStreamTranscriber`
/// always calls these with `inputDeviceID: nil`; this wrapper substitutes our stored
/// device ID so recording routes to the user-selected microphone.
///
/// We use composition rather than subclassing because WhisperKit declares
/// `startRecordingLive` / `resumeRecordingLive` in a class extension of
/// `AudioProcessor`, and Swift forbids overriding extension methods.
///
/// - Note: `preferredDeviceID == nil` means "use the caller's device ID", which in
///   practice falls through to the system default input.
final class DeviceSelectingAudioProcessor: AudioProcessing, @unchecked Sendable {

    // `var` so the existential's property setters (e.g. `relativeEnergyWindow`) are
    // callable through the wrapper. The reference is written once in `init`.
    private var inner: any AudioProcessing
    private let preferredDeviceID: DeviceID?

    /// - Parameters:
    ///   - preferredDeviceID: Device ID to substitute when callers pass `nil`. If `nil`,
    ///     the wrapper is effectively transparent.
    ///   - inner: Underlying processor. Defaults to a fresh `AudioProcessor()` but can
    ///     be replaced with a fake for testing.
    init(preferredDeviceID: DeviceID?, inner: any AudioProcessing = AudioProcessor()) {
        self.preferredDeviceID = preferredDeviceID
        self.inner = inner
    }

    // MARK: - Device-aware interception

    func startRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        try inner.startRecordingLive(inputDeviceID: resolved, callback: callback)
    }

    func resumeRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        try inner.resumeRecordingLive(inputDeviceID: resolved, callback: callback)
    }

    func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let resolved = preferredDeviceID ?? inputDeviceID
        return inner.startStreamingRecordingLive(inputDeviceID: resolved)
    }

    // MARK: - Plain delegation

    var audioSamples: ContiguousArray<Float> { inner.audioSamples }

    func purgeAudioSamples(keepingLast keep: Int) {
        inner.purgeAudioSamples(keepingLast: keep)
    }

    var relativeEnergy: [Float] { inner.relativeEnergy }

    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }

    func pauseRecording() { inner.pauseRecording() }
    func stopRecording() { inner.stopRecording() }

    func padOrTrim(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int
    ) -> (any AudioProcessorOutputType)? {
        inner.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    // MARK: - Static delegation

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

    static func loadAudio(
        at audioPaths: [String],
        channelMode: ChannelMode
    ) async -> [Result<[Float], Swift.Error>] {
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
}
