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

    /// Picks the device capture should be on now. Asked when the hardware
    /// changes mid-session, so e.g. unplugging the Studio Display moves
    /// capture to the built-in mic. `nil` keeps the device pinned.
    private let reselectDevice: (@Sendable () -> DeviceID?)?

    /// Observer for the live engine's configuration-change notification.
    /// Guarded by `observerLock` — set on the transcriber's executor, read
    /// on whatever thread stops recording.
    private var configObserver: NSObjectProtocol?
    private let observerLock = NSLock()

    // Recovery state — all guarded by `observerLock`.
    private static let maxRecoveryAttempts = 6
    private var requestedDeviceID: DeviceID?
    private var isRecording = false
    private var recoveryPending = false
    private var recoveryAttempts = 0
    private var sessionGeneration = 0
    private var captureFailure: String?
    /// The device the live engine is bound to; changes when capture follows
    /// a new system default.
    private var boundDeviceID: DeviceID?

    /// - Parameters:
    ///   - preferredDeviceID: Device ID to substitute when callers pass `nil`. If `nil`,
    ///     the wrapper is effectively transparent.
    ///   - reselectDevice: Re-picks the input after a mid-session hardware change.
    ///   - inner: Underlying processor. Defaults to a fresh `AudioProcessor()` but can
    ///     be replaced with a fake for testing.
    init(
        preferredDeviceID: DeviceID?,
        reselectDevice: (@Sendable () -> DeviceID?)? = nil,
        inner: any AudioProcessing = AudioProcessor()
    ) {
        self.preferredDeviceID = preferredDeviceID
        self.reselectDevice = reselectDevice
        self.inner = inner
    }

    // MARK: - Device-aware interception

    func startRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        try inner.startRecordingLive(inputDeviceID: resolved, callback: callback)
        beginSession(requestedDeviceID: inputDeviceID, fresh: true)
        observeEngineConfigurationChanges()
    }

    func resumeRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        try inner.resumeRecordingLive(inputDeviceID: resolved, callback: callback)
        beginSession(requestedDeviceID: inputDeviceID, fresh: false)
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
        observerLock.lock()
        isRecording = false
        sessionGeneration += 1
        recoveryPending = false
        observerLock.unlock()
        removeConfigurationObserver()
        inner.stopRecording()
    }

    // MARK: - Route-change recovery

    /// True once recovery from an engine configuration change has exhausted its
    /// retries (or is impossible), i.e. the session is no longer capturing audio.
    var captureFailed: Bool {
        observerLock.lock(); defer { observerLock.unlock() }
        return captureFailure != nil
    }

    /// Description of the last unrecoverable capture error, if any.
    var captureFailureDescription: String? {
        observerLock.lock(); defer { observerLock.unlock() }
        return captureFailure
    }

    /// AVAudioEngine stops itself when the audio hardware configuration
    /// changes (Bluetooth connect, output switched in the Sound menu, ...). The
    /// hardware format may change too, so restarting the old engine fails with
    /// -10868 and the old tap/converter are invalid. Instead tear the engine
    /// down and build a fresh one via `AudioProcessor.setupEngine`, which reads
    /// the current hardware format and installs a new tap. `audioSamples` and
    /// `audioBufferCallback` live on the processor, not the engine, so captured
    /// audio and the streaming callback survive.
    ///
    /// (`resumeRecordingLive` is deliberately not used: with the same device ID
    /// it only calls `audioEngine?.start()`, a no-op once `stopRecording()` has
    /// nil-ed the engine.)
    private func observeEngineConfigurationChanges() {
        guard let engine = (inner as? AudioProcessor)?.audioEngine else { return }
        removeConfigurationObserver()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRecovery()
        }
        observerLock.lock()
        configObserver = observer
        observerLock.unlock()
    }

    private func scheduleRecovery() {
        observerLock.lock()
        guard isRecording, !recoveryPending else {
            observerLock.unlock()
            return
        }
        recoveryPending = true
        let generation = sessionGeneration
        observerLock.unlock()
        // Debounce: route changes usually arrive in bursts while the hardware settles.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.recoverCapture(generation: generation)
        }
    }

    private func recoverCapture(generation: Int) {
        observerLock.lock()
        guard generation == sessionGeneration, isRecording else {
            recoveryPending = false
            observerLock.unlock()
            return
        }
        // If the right device changed (Studio Display unplugged or plugged
        // in), rebuild on it even if the old engine is still running.
        let bound = boundDeviceID
        let newTarget = reselectDevice?()
        let switchDevice = newTarget != nil && newTarget != bound
        // Configuration changes also fire when nothing broke — starting the mic,
        // another app pausing playback. If the engine is still running, capture
        // is intact; rebuilding would drop audio (and re-trigger the notification).
        let engine = (inner as? AudioProcessor)?.audioEngine
        if !switchDevice, let engine, engine.isRunning {
            recoveryPending = false
            observerLock.unlock()
            traceDeviceProcessor("engine configuration changed — engine still running, no rebuild")
            return
        }
        // Stopped, but often only by an output-side change (Spotify pausing on a
        // Bluetooth headset) with the input format unchanged: restarting the same
        // engine keeps the tap and is far quicker than a rebuild. A changed input
        // format makes start() throw, and we fall through to the rebuild.
        // (start() outside the lock: it can post the notification synchronously.)
        observerLock.unlock()
        if !switchDevice, let engine, (try? engine.start()) != nil, engine.isRunning {
            observerLock.lock()
            let stillCurrent = generation == sessionGeneration && isRecording
            recoveryPending = false
            observerLock.unlock()
            // Stopped while we were restarting: don't leave an orphaned engine running.
            guard stillCurrent else { engine.stop(); return }
            traceDeviceProcessor("engine configuration changed — restarted engine in place")
            return
        }
        observerLock.lock()
        guard generation == sessionGeneration, isRecording else {
            recoveryPending = false
            observerLock.unlock()
            return
        }
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            recoveryPending = false
            captureFailure = captureFailure ?? "recovery attempts exhausted"
            observerLock.unlock()
            traceDeviceProcessor("engine configuration changed — giving up after \(Self.maxRecoveryAttempts) attempts; capture has stopped")
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let deviceID = switchDevice ? newTarget : bound
        observerLock.unlock()

        guard let processor = inner as? AudioProcessor else {
            fail(generation: generation, "inner processor is not an AudioProcessor; cannot rebuild engine")
            return
        }

        removeConfigurationObserver()
        // Tears down the old engine and nils `audioEngine`; samples/callback untouched.
        processor.stopRecording()
        do {
            processor.audioEngine = try processor.setupEngine(inputDeviceID: deviceID)
        } catch {
            traceDeviceProcessor("engine configuration changed — rebuild attempt \(attempt) FAILED: \(error)")
            observerLock.lock()
            captureFailure = "\(error)"
            recoveryPending = false
            let stillCurrent = generation == sessionGeneration && isRecording
            observerLock.unlock()
            // Hardware may still be settling: retry (bounded by the attempt cap).
            if stillCurrent { retryRecovery(generation: generation) }
            return
        }

        observerLock.lock()
        let stillCurrent = generation == sessionGeneration && isRecording
        if stillCurrent {
            captureFailure = nil
            boundDeviceID = deviceID
        }
        recoveryPending = false
        observerLock.unlock()
        if stillCurrent {
            observeEngineConfigurationChanges()
            let note = switchDevice
                ? "switched to \(deviceID.map(String.init) ?? "nil") from \(bound.map(String.init) ?? "nil")"
                : "same device"
            traceDeviceProcessor("engine configuration changed — rebuilt capture (attempt \(attempt), \(note)), samples kept")
        } else {
            // Stopped while we were rebuilding: don't leave a live engine behind.
            processor.stopRecording()
        }
    }

    private func retryRecovery(generation: Int) {
        observerLock.lock()
        guard !recoveryPending else { observerLock.unlock(); return }
        recoveryPending = true
        observerLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recoverCapture(generation: generation)
        }
    }

    private func fail(generation: Int, _ message: String) {
        observerLock.lock()
        if generation == sessionGeneration { captureFailure = message }
        recoveryPending = false
        observerLock.unlock()
        traceDeviceProcessor("engine configuration changed — \(message)")
    }

    private func removeConfigurationObserver() {
        observerLock.lock()
        let observer = configObserver
        configObserver = nil
        observerLock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Marks a new recording session (`fresh` resets the retry budget and failure state).
    private func beginSession(requestedDeviceID: DeviceID?, fresh: Bool) {
        observerLock.lock()
        self.requestedDeviceID = requestedDeviceID
        boundDeviceID = preferredDeviceID ?? requestedDeviceID
        isRecording = true
        if fresh {
            sessionGeneration += 1
            recoveryAttempts = 0
            recoveryPending = false
            captureFailure = nil
        }
        observerLock.unlock()
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
