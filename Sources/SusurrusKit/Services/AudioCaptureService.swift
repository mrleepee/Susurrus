@preconcurrency import AVFoundation

/// Concrete audio capture using AVAudioEngine.
/// Captures mono 16kHz PCM from the system default input device.
public actor AudioCaptureService: AudioCapturing {

    private var engine: AVAudioEngine?
    private var audioBuffers: [[Float]] = []
    private var capturing = false

    public init() {}

    public func isCurrentlyCapturing() async -> Bool {
        capturing
    }

    public func startCapture() async throws {
        guard !capturing else {
            throw AudioCaptureError.alreadyCapturing
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineFailure("Failed to create target format")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.engineFailure("Failed to create audio converter")
        }

        audioBuffers = []

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            Task { [weak self] in
                await self?.processBuffer(buffer, converter: converter, targetFormat: targetFormat)
            }
        }

        try engine.start()
        self.engine = engine
        capturing = true
    }

    public func stopCapture() async throws -> [Float] {
        guard capturing else {
            throw AudioCaptureError.notCapturing
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        capturing = false

        let result = audioBuffers.flatMap { $0 }
        audioBuffers = []
        return result
    }

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetFrameCount
        ) else { return }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else { return }

        if let channelData = outputBuffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(
                start: channelData,
                count: Int(outputBuffer.frameLength)
            ))
            audioBuffers.append(samples)
        }
    }
}
