@preconcurrency import AVFoundation
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

    /// Observer for the live engine's configuration-change notification.
    /// Guarded by `observerLock` — set on the transcriber's executor, read
    /// on whatever thread stops recording.
    private var configObserver: NSObjectProtocol?
    private let observerLock = NSLock()

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
        observeEngineConfigurationChanges()
    }

    func resumeRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        try inner.resumeRecordingLive(inputDeviceID: resolved, callback: callback)
        observeEngineConfigurationChanges()
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

    func stopRecording() {
        removeConfigurationObserver()
        inner.stopRecording()
    }

    // MARK: - Route-change recovery

    /// AVAudioEngine stops itself when the audio hardware configuration
    /// changes — e.g. a Bluetooth speaker connecting or the user switching
    /// output in the Sound menu mid-dictation. WhisperKit doesn't listen for
    /// this, so the session silently records nothing from then on. Restart
    /// the engine: the input device is pinned, so the existing tap and
    /// converter stay valid.
    private func observeEngineConfigurationChanges() {
        guard let engine = (inner as? AudioProcessor)?.audioEngine else { return }
        removeConfigurationObserver()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak engine] _ in
            guard let engine, !engine.isRunning else { return }
            do {
                try engine.start()
                traceDeviceProcessor("engine configuration changed — restarted capture")
            } catch {
                traceDeviceProcessor("engine configuration changed — restart FAILED: \(error)")
            }
        }
        observerLock.lock()
        configObserver = observer
        observerLock.unlock()
    }

    private func removeConfigurationObserver() {
        observerLock.lock()
        let observer = configObserver
        configObserver = nil
        observerLock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

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

/// Writes to ~/susurrus_debug.log — same sink as traceApp() in the app layer.
private func traceDeviceProcessor(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [audio] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}
