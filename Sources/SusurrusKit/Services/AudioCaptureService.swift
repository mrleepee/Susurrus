@preconcurrency import AVFoundation

/// Concrete audio capture using AVAudioEngine.
/// Captures mono 16kHz PCM from the system default input device.
///
/// Optimisations:
/// - Engine and tap are created once and reused across recordings
/// - Pre-allocated contiguous buffer avoids per-callback allocations and flatMap
/// - Format conversion and buffer copy happen synchronously in the audio tap
///   to avoid data loss from the engine reusing the PCM buffer
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {

    private nonisolated(unsafe) var engine: AVAudioEngine?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var tapFormat: AVAudioFormat?
    private nonisolated(unsafe) var conversionBuffer: AVAudioPCMBuffer?

    /// The device ID the current `engine` was configured for (if any).
    /// Kept so we can tear down and rebuild when the caller requests a
    /// different device — a device change can alter the hardware sample
    /// rate, invalidating the cached converter.
    private nonisolated(unsafe) var currentDeviceID: UInt32?

    /// Lock protects the capture buffer, write index, and capturing flag
    /// which are accessed from both the audio tap callback and public methods.
    private nonisolated(unsafe) var unfairLock = os_unfair_lock_s()

    /// Pre-allocated buffer for 60s at 16kHz mono.
    private nonisolated(unsafe) var audioBuffer = ContiguousArray<Float>(repeating: 0, count: 60 * 16_000)
    private nonisolated(unsafe) var writeIndex: Int = 0
    private nonisolated(unsafe) var capturingFlag: Bool = false

    public init() {}

    private func lock() { os_unfair_lock_lock(&unfairLock) }
    private func unlock() { os_unfair_lock_unlock(&unfairLock) }

    /// Resets the capturing flag. Call inside lock.
    private func resetCapturingFlag() {
        capturingFlag = false
    }

    public func isCurrentlyCapturing() async -> Bool {
        lock()
        defer { unlock() }
        return capturingFlag
    }

    public func startCapture(deviceID: UInt32?) async throws {
        lock()
        guard !capturingFlag else {
            unlock()
            throw AudioCaptureError.alreadyCapturing
        }
        writeIndex = 0
        capturingFlag = true
        unlock()

        // If setupEngine() or engine.start() throws, we must reset the flag
        // so later recording attempts don't fail with .alreadyCapturing.
        do {
            // Rebuild the engine when the requested device changes — the
            // cached converter is tied to the previous device's hardware format.
            if engine != nil, currentDeviceID != deviceID {
                teardownEngine()
            }

            if engine == nil {
                try setupEngine(deviceID: deviceID)
            }

            guard let engine else {
                lock(); resetCapturingFlag(); unlock()
                throw AudioCaptureError.engineFailure("Engine not available")
            }

            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            lock(); resetCapturingFlag(); unlock()
            throw error
        }
    }

    public func stopCapture() async throws -> [Float] {
        lock()
        guard capturingFlag else {
            unlock()
            throw AudioCaptureError.notCapturing
        }
        capturingFlag = false
        let result = Array(audioBuffer[0..<writeIndex])
        writeIndex = 0
        unlock()

        // Stop engine to release audio hardware, but keep tap installed
        engine?.stop()

        return result
    }

    // MARK: - Engine Setup (once per device)

    private func teardownEngine() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil
        tapFormat = nil
        conversionBuffer = nil
        currentDeviceID = nil
    }

    private func setupEngine(deviceID: UInt32?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Assign the specific input device before querying its format, so the
        // converter is built for the device the tap will actually read from.
        if let deviceID {
            try assignInputDevice(inputNode: inputNode, deviceID: deviceID)
        }

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineFailure("Failed to create target format")
        }

        guard let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.engineFailure("Failed to create audio converter")
        }

        self.converter = conv
        self.tapFormat = targetFormat

        // Pre-allocate conversion buffer (reused in every tap callback).
        // 8192 frames covers the largest possible callback at any sample rate.
        guard let preAllocated = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: 8192
        ) else {
            throw AudioCaptureError.engineFailure("Failed to pre-allocate conversion buffer")
        }
        self.conversionBuffer = preAllocated

        // Install tap once — stays installed for the lifetime of the service.
        // All conversion and copying happens synchronously inside the callback
        // because the AVAudioPCMBuffer is only valid during this call.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processBufferSync(buffer)
        }

        self.engine = engine
        self.currentDeviceID = deviceID
    }

    #if os(macOS)
    /// Route the input node to a specific Core Audio device.
    /// Mirrors WhisperKit's `assignAudioInput` (AudioProcessor.swift:929).
    private func assignInputDevice(inputNode: AVAudioInputNode, deviceID: UInt32) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.engineFailure("Input node has no audio unit")
        }
        var id = deviceID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if err != noErr {
            throw AudioCaptureError.engineFailure("AudioUnitSetProperty failed: OSStatus \(err)")
        }
    }
    #else
    private func assignInputDevice(inputNode: AVAudioInputNode, deviceID: UInt32) throws {
        // No-op on non-macOS platforms — device routing is handled by AVAudioSession.
    }
    #endif

    // MARK: - Synchronous Buffer Processing

    /// Called directly from the audio tap callback.
    /// Converts outside the lock, then copies inside the lock for minimal hold time.
    private func processBufferSync(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let convBuf = conversionBuffer else { return }

        // 1. Convert OUTSIDE the lock — no contention with audio thread

        // Reset conversion buffer frame length for this conversion
        convBuf.frameLength = 0

        var error: NSError?
        var inputConsumed = false
        let status = converter.convert(to: convBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != AVAudioConverterOutputStatus.error, error == nil else { return }

        // 2. Quick copy INSIDE the lock — minimal hold time
        guard let channelData = convBuf.floatChannelData?[0] else { return }
        let sampleCount = Int(convBuf.frameLength)

        lock()
        guard capturingFlag else {
            unlock()
            return
        }
        let available = audioBuffer.count - writeIndex
        let toCopy = min(sampleCount, available)
        if toCopy > 0 {
            audioBuffer.replaceSubrange(
                writeIndex..<(writeIndex + toCopy),
                with: UnsafeBufferPointer(start: channelData, count: toCopy)
            )
            writeIndex += toCopy
        }
        unlock()
    }
}
