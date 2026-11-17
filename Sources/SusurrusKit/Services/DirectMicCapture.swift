@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
@preconcurrency import WhisperKit

/// Captures one input device straight from Core Audio and delivers 16 kHz
/// mono `Float` buffers, the format WhisperKit's `AudioProcessor.processBuffer`
/// expects.
///
/// This replaces `AVAudioEngine` for capture. An engine always opens the
/// default *output* device as well, so with a Bluetooth speaker as the output
/// (and in its 16 kHz call profile) the input tap silently delivers zero
/// frames even when the built-in mic is pinned and the engine reports it is
/// running. A device IOProc touches only the input device we ask for.
///
/// The IOProc runs on the realtime audio thread and only appends to a locked
/// buffer; a timer on a private queue drains it every 100 ms, resamples, and
/// hands the result to `onSamples`.
final class DirectMicCapture: @unchecked Sendable {

    enum CaptureError: Error, CustomStringConvertible {
        case formatUnavailable(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .formatUnavailable(let s): return "input format unavailable (OSStatus \(s))"
            case .ioProcFailed(let s): return "could not create IOProc (OSStatus \(s))"
            case .startFailed(let s): return "could not start device (OSStatus \(s))"
            }
        }
    }

    static let targetSampleRate = Double(WhisperKit.sampleRate)
    private static let drainInterval: DispatchTimeInterval = .milliseconds(100)

    let deviceID: AudioDeviceID
    private let onSamples: ([Float]) -> Void

    private let pending = OSAllocatedUnfairLock(initialState: [Float]())
    private let framesLock = OSAllocatedUnfairLock(initialState: 0)
    private let drainQueue = DispatchQueue(label: "Susurrus.audio.drain", qos: .userInteractive)
    private var ioProcID: AudioDeviceIOProcID?
    private var drainTimer: DispatchSourceTimer?
    private var started = false

    private var nativeFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(deviceID: AudioDeviceID, onSamples: @escaping ([Float]) -> Void) {
        self.deviceID = deviceID
        self.onSamples = onSamples
    }

    /// Total device frames received so far. A stalled device stops advancing.
    var framesReceived: Int { framesLock.withLock { $0 } }

    func start() throws {
        guard !started else { return }

        let rate = try Self.inputRate(of: deviceID)
        guard let native = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        ), let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false
        ) else {
            throw CaptureError.formatUnavailable(kAudioHardwareUnspecifiedError)
        }
        nativeFormat = native
        converter = rate == Self.targetSampleRate ? nil : AVAudioConverter(from: native, to: target)
        pending.withLock { $0.removeAll(keepingCapacity: true); $0.reserveCapacity(Int(rate)) }
        framesLock.withLock { $0 = 0 }

        let pending = self.pending
        let framesLock = self.framesLock
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = list.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / ch
            guard frames > 0 else { return }
            pending.withLock { buf in
                if ch == 1 {
                    buf.append(contentsOf: UnsafeBufferPointer(start: data, count: frames))
                } else {
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<ch { sum += data[i * ch + c] }
                        buf.append(sum / Float(ch))
                    }
                }
            }
            framesLock.withLock { $0 += frames }
        }
        guard created == noErr, let procID else { throw CaptureError.ioProcFailed(created) }

        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw CaptureError.startFailed(status)
        }
        ioProcID = procID

        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
        started = true
    }

    func stop() {
        guard started else { return }
        started = false
        drainTimer?.cancel()
        drainTimer = nil
        if let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
        }
        // Deliver what was captured between the last tick and the stop.
        drainQueue.sync { drain() }
    }

    private func drain() {
        let chunk = pending.withLock { buf -> [Float] in
            let out = buf
            buf.removeAll(keepingCapacity: true)
            return out
        }
        guard !chunk.isEmpty else { return }
        let out = process(nativeChunk: chunk)
        if !out.isEmpty { onSamples(out) }
    }

    /// Resamples a mono chunk at the device's native rate to 16 kHz.
    /// Internal so it can be tested without hardware.
    func process(nativeChunk chunk: [Float]) -> [Float] {
        guard let nativeFormat else { return chunk }
        guard let converter else { return chunk }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else {
            return []
        }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: chunk.count)
        }
        guard let resampled = try? AudioProcessor.resampleBuffer(buffer, with: converter) else { return [] }
        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    /// Test hook: set the native rate without a device.
    func prepareForTesting(sampleRate: Double) {
        nativeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        if let nativeFormat, sampleRate != Self.targetSampleRate,
           let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false) {
            converter = AVAudioConverter(from: nativeFormat, to: target)
        }
    }

    // MARK: - Core Audio

    private static func inputRate(of device: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { throw CaptureError.formatUnavailable(status) }
        return asbd.mSampleRate
    }
}
