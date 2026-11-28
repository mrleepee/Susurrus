@preconcurrency import AVFoundation
import CoreAudio
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// An `AudioProcessing` wrapper that routes live capture to a specific Core Audio
/// input device. WhisperKit's `AudioStreamTranscriber` always calls
/// `startRecordingLive` with `inputDeviceID: nil`; this wrapper substitutes our
/// chosen device so recording comes from the intended microphone.
///
/// With a real `AudioProcessor` inside, capture does NOT go through WhisperKit's
/// `AVAudioEngine`: an engine also opens the default output device, and with a
/// Bluetooth speaker as output it delivers no audio at all even when pinned to
/// the built-in mic. Instead `DirectMicCapture` reads the input device directly
/// and feeds `AudioProcessor.processBuffer`, so samples, energy and the
/// streaming callback behave as before. With any other `AudioProcessing`
/// (test fakes) everything is delegated unchanged.
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

    private static let maxRecoveryAttempts = 6
    /// How long the input may deliver nothing before capture is restarted.
    private static let stallThreshold: TimeInterval = 1.5

    /// Serialises start/stop/recovery. Recursive so a restart can call stop.
    private let lock = NSRecursiveLock()

    // All guarded by `lock`.
    private var capture: DirectMicCapture?
    private var boundDeviceID: DeviceID?
    private var isRecording = false
    private var sessionGeneration = 0
    private var recoveryAttempts = 0
    private var recoveryPending = false
    private var captureFailure: String?
    private var lastFrameCount = 0
    private var lastFrameProgress = Date()
    private var watchdog: DispatchSourceTimer?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private let controlQueue = DispatchQueue(label: "Susurrus.audio.control")

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
        guard let processor = inner as? AudioProcessor else {
            try inner.startRecordingLive(inputDeviceID: resolved, callback: callback)
            return
        }
        processor.audioSamples = []
        processor.audioEnergy = []
        processor.audioBufferCallback = callback
        try beginDirectCapture(processor: processor, device: resolved, fresh: true)
    }

    func resumeRecordingLive(
        inputDeviceID: DeviceID?,
        callback: (([Float]) -> Void)?
    ) throws {
        let resolved = preferredDeviceID ?? inputDeviceID
        guard let processor = inner as? AudioProcessor else {
            try inner.resumeRecordingLive(inputDeviceID: resolved, callback: callback)
            return
        }
        if let callback { processor.audioBufferCallback = callback }
        try beginDirectCapture(processor: processor, device: resolved, fresh: false)
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

    func pauseRecording() {
        guard inner is AudioProcessor else { inner.pauseRecording(); return }
        lock.lock()
        isRecording = false
        sessionGeneration += 1
        recoveryPending = false
        stopMonitoring()
        capture?.stop()
        capture = nil
        lock.unlock()
    }

    func stopRecording() {
        lock.lock()
        isRecording = false
        sessionGeneration += 1
        recoveryPending = false
        stopMonitoring()
        capture?.stop()
        capture = nil
        lock.unlock()
        inner.stopRecording()
    }

    // MARK: - Direct capture

    /// True once capture could not be (re)started within the retry budget, i.e.
    /// the session is no longer recording audio.
    var captureFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return captureFailure != nil
    }

    /// Description of the last unrecoverable capture error, if any.
    var captureFailureDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return captureFailure
    }

    private func beginDirectCapture(processor: AudioProcessor, device: DeviceID?, fresh: Bool) throws {
        guard let deviceID = device ?? AudioDeviceService.systemDefaultInputID() else {
            throw TranscriptionError.transcriptionFailed("No audio input device available")
        }
        lock.lock()
        defer { lock.unlock() }
        capture?.stop()
        capture = nil
        let newCapture = DirectMicCapture(deviceID: deviceID) { [weak processor] samples in
            processor?.processBuffer(samples)
        }
        try newCapture.start()
        capture = newCapture
        boundDeviceID = deviceID
        isRecording = true
        if fresh {
            sessionGeneration += 1
            recoveryAttempts = 0
            captureFailure = nil
        }
        recoveryPending = false
        lastFrameCount = 0
        lastFrameProgress = Date()
        startMonitoring()
        traceDeviceProcessor("capturing directly from device \(deviceID)")
    }

    // MARK: - Recovery

    /// Watches for the two ways direct capture can go wrong mid-session: the
    /// audio hardware changes (Studio Display plugged in or out, a Bluetooth
    /// device connecting) so the right device may be a different one, or the
    /// device simply stops delivering frames. Either restarts capture on the
    /// device `reselectDevice` picks, within a bounded retry budget.
    private func startMonitoring() {
        stopMonitoring()

        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        watchdog = timer

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReselect()
        }
        deviceListListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener
        )
    }

    private func stopMonitoring() {
        watchdog?.cancel()
        watchdog = nil
        if let listener = deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener
            )
            deviceListListener = nil
        }
    }

    private func scheduleReselect() {
        lock.lock()
        guard isRecording, !recoveryPending else { lock.unlock(); return }
        recoveryPending = true
        let generation = sessionGeneration
        lock.unlock()
        // Device changes arrive in bursts while the hardware settles.
        controlQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.restartCapture(generation: generation, reason: "audio devices changed")
        }
    }

    private func checkForStall() {
        lock.lock()
        guard isRecording, let capture else { lock.unlock(); return }
        let frames = capture.framesReceived
        if frames != lastFrameCount {
            lastFrameCount = frames
            lastFrameProgress = Date()
            recoveryAttempts = 0
            lock.unlock()
            return
        }
        let stalled = Date().timeIntervalSince(lastFrameProgress) >= Self.stallThreshold
        let generation = sessionGeneration
        let busy = recoveryPending
        if stalled, !busy { recoveryPending = true }
        lock.unlock()
        if stalled, !busy {
            restartCapture(generation: generation, reason: "no audio for \(Self.stallThreshold)s")
        }
    }

    private func restartCapture(generation: Int, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == sessionGeneration, isRecording, let processor = inner as? AudioProcessor else {
            recoveryPending = false
            return
        }
        let bound = boundDeviceID
        let target = reselectDevice?() ?? bound
        let switching = target != bound

        // A device-list change that doesn't affect us: leave a healthy capture alone.
        if !switching, let capture, capture.framesReceived != lastFrameCount {
            recoveryPending = false
            return
        }
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            recoveryPending = false
            captureFailure = captureFailure ?? "no audio from the input device after \(Self.maxRecoveryAttempts) restarts"
            traceDeviceProcessor("\(reason) — giving up; capture has stopped")
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        capture?.stop()
        capture = nil
        guard let deviceID = target else {
            recoveryPending = false
            captureFailure = "no input device available"
            return
        }
        let newCapture = DirectMicCapture(deviceID: deviceID) { [weak processor] samples in
            processor?.processBuffer(samples)
        }
        do {
            try newCapture.start()
            capture = newCapture
            boundDeviceID = deviceID
            lastFrameCount = 0
            lastFrameProgress = Date()
            recoveryPending = false
            let note = switching
                ? "switched to \(deviceID) from \(bound.map(String.init) ?? "nil")"
                : "same device \(deviceID)"
            traceDeviceProcessor("\(reason) — restarted capture (attempt \(attempt), \(note)), samples kept")
        } catch {
            traceDeviceProcessor("\(reason) — restart attempt \(attempt) FAILED: \(error)")
            recoveryPending = false
            // The hardware may still be settling: the watchdog tries again.
            lastFrameProgress = Date().addingTimeInterval(-Self.stallThreshold)
        }
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
    guard !DebugLog.isTestProcess else { return }
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
