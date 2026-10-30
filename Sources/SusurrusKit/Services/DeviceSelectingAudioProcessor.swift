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

    /// When true, a mid-session hardware change re-binds capture to whatever
    /// macOS now has as its default input (e.g. a Bluetooth speaker that just
    /// connected). When false the user picked a device, so it stays pinned.
    private let followsSystemDefault: Bool

    /// Serialises engine rebuilds against start/stop. `engineLock` guards
    /// `isRecording`, `boundDeviceID` and `rerouteGeneration`. Recursive in
    /// case Core Audio posts a configuration change synchronously mid-rebuild.
    private let engineLock = NSRecursiveLock()
    private var isRecording = false
    private var boundDeviceID: DeviceID?
    private var rerouteGeneration = 0
    private static let rerouteQueue = DispatchQueue(label: "Susurrus.audio.reroute")

    /// Observer for the live engine's configuration-change notification.
    /// Guarded by `observerLock` — set on the transcriber's executor, read
    /// on whatever thread stops recording.
    private var configObserver: NSObjectProtocol?
    private let observerLock = NSLock()

    /// - Parameters:
    ///   - preferredDeviceID: Device ID to substitute when callers pass `nil`. If `nil`,
    ///     the wrapper is effectively transparent.
    ///   - followsSystemDefault: Re-bind to the new macOS default input when
    ///     the audio hardware changes mid-session.
    ///   - inner: Underlying processor. Defaults to a fresh `AudioProcessor()` but can
    ///     be replaced with a fake for testing.
    init(
        preferredDeviceID: DeviceID?,
        followsSystemDefault: Bool = false,
        inner: any AudioProcessing = AudioProcessor()
    ) {
        self.preferredDeviceID = preferredDeviceID
        self.followsSystemDefault = followsSystemDefault
        self.inner = inner
    }

    // MARK: - Device-aware interception

    func startRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        engineLock.lock()
        defer { engineLock.unlock() }
        try inner.startRecordingLive(inputDeviceID: resolved, callback: callback)
        isRecording = true
        boundDeviceID = resolved
        observeEngineConfigurationChanges()
    }

    func resumeRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        engineLock.lock()
        defer { engineLock.unlock() }
        try inner.resumeRecordingLive(inputDeviceID: resolved, callback: callback)
        isRecording = true
        boundDeviceID = resolved
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
        engineLock.lock()
        defer { engineLock.unlock() }
        isRecording = false
        rerouteGeneration += 1
        removeConfigurationObserver()
        inner.stopRecording()
    }

    // MARK: - Route-change recovery

    /// AVAudioEngine stops itself when the audio hardware configuration
    /// changes — e.g. a Bluetooth speaker connecting (which can also make its
    /// mic the macOS default input and change the sample rate) or the user
    /// switching devices in the Sound menu mid-dictation. WhisperKit doesn't
    /// listen for this, so the session silently records nothing from then
    /// on. Changes arrive in bursts while the device settles, so they are
    /// coalesced and the engine is rebuilt once things are quiet.
    private func observeEngineConfigurationChanges() {
        guard let engine = (inner as? AudioProcessor)?.audioEngine else { return }
        removeConfigurationObserver()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleReroute()
        }
        observerLock.lock()
        configObserver = observer
        observerLock.unlock()
    }

    private func scheduleReroute() {
        engineLock.lock()
        rerouteGeneration += 1
        let generation = rerouteGeneration
        engineLock.unlock()
        Self.rerouteQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reroute(generation: generation, attempt: 1)
        }
    }

    /// Re-binds capture to the right device without losing what has been
    /// recorded so far: the follow-the-default case moves to the new macOS
    /// default input; a pinned device is reopened (its format may have
    /// changed, which is why a plain `engine.start()` fails with -10868).
    private func reroute(generation: Int, attempt: Int) {
        guard let processor = inner as? AudioProcessor else { return }
        engineLock.lock()
        defer { engineLock.unlock() }
        guard isRecording, generation == rerouteGeneration else { return }

        let bound = boundDeviceID
        let target = followsSystemDefault
            ? (AudioDeviceService.systemDefaultInputID() ?? bound)
            : bound
        if target == bound, processor.audioEngine?.isRunning == true { return }

        // `startRecordingLive` builds a fresh engine, tap and converter for
        // the device's current format, but clears the sample buffer — carry
        // the session's audio across.
        let saved = processor.audioSamples
        let callback = processor.audioBufferCallback
        removeConfigurationObserver()
        processor.stopRecording()
        do {
            try processor.startRecordingLive(inputDeviceID: target, callback: callback)
            processor.audioSamples = saved + processor.audioSamples
            boundDeviceID = target
            observeEngineConfigurationChanges()
            let note = target == bound ? "reopened device" : "switched from \(bound.map(String.init) ?? "nil")"
            traceDeviceProcessor("hardware changed — capturing from \(target.map(String.init) ?? "nil") (\(note))")
        } catch {
            processor.audioSamples = saved
            traceDeviceProcessor("hardware changed — rebind to \(target.map(String.init) ?? "nil") failed (attempt \(attempt)): \(error)")
            // The device is often still settling; try again shortly.
            guard attempt < 4 else { return }
            Self.rerouteQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.reroute(generation: generation, attempt: attempt + 1)
            }
        }
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
