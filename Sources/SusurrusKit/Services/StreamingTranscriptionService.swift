import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Writes to ~/susurrus_debug.log — same sink as traceApp() in the app layer.
private func traceStream(_ message: String) {
    let path = NSHomeDirectory() + "/susurrus_debug.log"
    let line = "\(Date()) [stream] \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

private func msSince(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

/// Streaming transcription service using WhisperKit's AudioStreamTranscriber.
/// Manages a live audio pipeline and delivers interim transcripts via callback.
public actor StreamingTranscriptionService {

    // MARK: - Types

    /// Callback type for delivering interim transcripts.
    /// Fired on the AudioStreamTranscriber's executor; re-dispatched to this actor.
    public typealias InterimCallback = @Sendable (InterimTranscript) -> Void

    // MARK: - Constants

    /// WhisperKit operates on 16kHz mono PCM.
    private static let sampleRate = 16_000

    /// Minimum session length worth re-transcribing on stop (0.5s).
    private static let minFinalFlushSamples = 8_000

    /// Un-decoded tails shorter than this (0.3s) can't contain a word —
    /// skip the final decode so finalization is instant.
    private static let minTailSamples = 4_800

    /// Peak amplitude below which the un-decoded tail is considered silence
    /// (user paused before releasing the hotkey — the common case) and the
    /// final decode is skipped.
    private static let tailSilencePeak: Float = 0.015

    // MARK: - State

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var modelReady = false

    /// Vocabulary prompt applied to each decode session.
    private var vocabularyPrompt: String = ""

    /// Callback invoked on each interim transcript update.
    private var interimCallback: InterimCallback?

    /// The last observed state from the transcriber's callback.
    /// Used by stopStreamTranscription() as a fallback when the final
    /// flush over the session buffer fails.
    private var lastTranscriberState: AudioStreamTranscriber.State?

    /// Tracks whether the stream has emitted a final transcript.
    private var finalTextEmitted = false

    /// The audio processor feeding the current session. Retained so
    /// stopStreamTranscription() can read the full session buffer for the
    /// final flush after the realtime loop has exited.
    private var activeProcessor: (any AudioProcessing)?

    /// Decoding options for the current session, reused by the final flush
    /// so vocabulary biasing applies to the last pass too.
    private var activeDecodingOptions: DecodingOptions?

    /// The task running the transcriber's realtime loop. Stored so
    /// stopStreamTranscription() can await the loop draining its in-flight
    /// decode pass instead of racing it for the ANE.
    private var sessionTask: Task<Void, Error>?

    // MARK: - Init

    public init() {}

    // MARK: - Model lifecycle

    /// Whether the model is loaded and ready.
    public func isModelReady() -> Bool {
        modelReady
    }

    /// Load the model from the given folder.
    public func setupModel(
        modelName: String = "base",
        computeOptions: ModelComputeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        ),
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let downloadBase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Susurrus")

        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: downloadBase,
            progressCallback: { progress in
                guard progress.totalUnitCount > 0 else { return }
                let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                onDownloadProgress?(fraction)
            }
        )

        let kit = try await WhisperKit(modelFolder: modelFolder.path, computeOptions: computeOptions)
        self.whisperKit = kit
        modelReady = true
    }

    /// Unload the model and stop any active stream.
    public func unloadModel() {
        streamTranscriber = nil
        whisperKit = nil
        modelReady = false
        lastTranscriberState = nil
        finalTextEmitted = false
        activeProcessor = nil
        activeDecodingOptions = nil
        sessionTask = nil
    }

    // MARK: - Vocabulary

    /// Set the vocabulary prompt for biasing transcription.
    public func setVocabularyPrompt(_ prompt: String) {
        vocabularyPrompt = prompt
    }

    // MARK: - Streaming transcription

    /// Begin streaming transcription.
    /// The callback fires with interim transcripts as text is confirmed.
    ///
    /// - Parameters:
    ///   - deviceID: Core Audio input device ID to record from, or `nil` for system default.
    ///   - callback: Called on each state change with confirmed/unconfirmed text.
    /// - Throws: `TranscriptionError.modelNotReady` if the model is not loaded.
    public func startStreamTranscription(
        deviceID: UInt32? = nil,
        callback: @escaping InterimCallback
    ) async throws {
        try await startStreamTranscription(
            deviceID: deviceID,
            audioProcessorOverride: nil,
            callback: callback
        )
    }

    /// Internal entry point that accepts an injected audio processor for testing.
    /// Pass `nil` override to use a real `AudioProcessor` routed to `deviceID`
    /// (or the shared `whisperKit.audioProcessor` when `deviceID` is also `nil`).
    internal func startStreamTranscription(
        deviceID: UInt32?,
        audioProcessorOverride: (any AudioProcessing)?,
        callback: @escaping InterimCallback
    ) async throws {
        guard modelReady, let whisperKit else {
            throw TranscriptionError.modelNotReady
        }

        guard let tokenizer = whisperKit.tokenizer else {
            throw TranscriptionError.transcriptionFailed("Tokenizer not available")
        }

        self.interimCallback = callback
        self.lastTranscriberState = nil
        self.finalTextEmitted = false

        // Build DecodingOptions, applying vocabulary prompt if set
        var options = DecodingOptions(
            task: .transcribe,
            language: nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )

        if !vocabularyPrompt.isEmpty {
            options.promptTokens = tokenizer.encode(text: vocabularyPrompt)
        }

        // Resolve which processor to use:
        //   1. Test override, if provided.
        //   2. A DeviceSelectingAudioProcessor that forces a specific input device.
        //   3. WhisperKit's shared default processor (system default input).
        let processor: any AudioProcessing
        if let audioProcessorOverride {
            processor = audioProcessorOverride
        } else if let deviceID {
            processor = DeviceSelectingAudioProcessor(preferredDeviceID: deviceID)
        } else {
            processor = whisperKit.audioProcessor
        }

        // Purge residual audio so session N+1 cannot see samples from session N
        // (applies to the shared processor; fresh processors are empty anyway).
        processor.purgeAudioSamples(keepingLast: 0)

        self.activeProcessor = processor
        self.activeDecodingOptions = options

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: processor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 1,
            silenceThreshold: 0.1,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                self?.enqueueStateChange(oldState: oldState, newState: newState)
            }
        )

        self.streamTranscriber = transcriber
        // Run the realtime loop in a stored task so stop can await loop exit;
        // awaiting .value here preserves the original blocking/throwing
        // behaviour for the caller (returns/throws when the session ends).
        let task = Task { try await transcriber.startStreamTranscription() }
        self.sessionTask = task
        try await task.value
    }

    /// Stop streaming transcription and return the final transcript.
    ///
    /// AudioStreamTranscriber's realtime loop exits WITHOUT processing audio
    /// buffered since its last decode pass, so relying on callback state alone
    /// loses the tail of the recording (often several seconds with large models).
    /// After stopping capture we therefore run a final decode over the session
    /// buffer to recover the full text, falling back to the last callback state
    /// only if that final pass fails.
    ///
    /// - Returns: The final text, or throws if no speech was detected.
    public func stopStreamTranscription() async throws -> String {
        guard let transcriber = streamTranscriber else {
            return ""
        }

        let stopStart = Date()

        // Stop audio capture; the realtime loop exits after its in-flight pass.
        await transcriber.stopStreamTranscription()

        // Wait for the realtime loop to drain rather than racing it — a
        // concurrent final decode contends with the in-flight pass for the
        // ANE and roughly doubles finalization time. When the loop exits, its
        // last pass results are already in lastTranscriberState.
        try? await sessionTask?.value
        traceStream("stop: loop drained in \(msSince(stopStart))ms")

        let state = lastTranscriberState
        let processor = activeProcessor
        streamTranscriber = nil
        interimCallback = nil
        activeProcessor = nil
        sessionTask = nil

        // Final flush over the session buffer.
        let flushStart = Date()
        if let finalText = await finalFlushText(processor: processor, state: state) {
            traceStream("stop: flush done in \(msSince(flushStart))ms, total \(msSince(stopStart))ms")
            processor?.purgeAudioSamples(keepingLast: 0)
            return finalText
        }
        traceStream("stop: flush produced nothing after \(msSince(flushStart))ms — falling back to streaming state")

        // Fallback: harvest whatever the streaming callbacks captured.
        processor?.purgeAudioSamples(keepingLast: 0)

        guard let state else {
            throw TranscriptionError.noSpeechDetected
        }

        let text = Self.extractFinalText(from: state)
        let cleaned = Self.stripNoiseTokens(from: text)

        guard !cleaned.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        return cleaned
    }

    /// Recovers words the realtime loop never decoded, while keeping
    /// finalization fast. Called AFTER the loop has drained, so the streaming
    /// state already reflects the final completed decode pass:
    ///
    /// 1. The only audio the streaming text can be missing is what arrived
    ///    after the final pass began — under one pass duration, typically <1s.
    /// 2. If that tail is too short to hold a word, or is silence (user paused
    ///    before releasing the hotkey — the common case), return the streaming
    ///    text with NO extra decode: instant.
    /// 3. Otherwise decode ONLY that tail (one Whisper window) and append it.
    ///
    /// - Returns: The cleaned final text, or `nil` if the flush could not
    ///   produce usable text (caller falls back to streaming state).
    private func finalFlushText(
        processor: (any AudioProcessing)?,
        state: AudioStreamTranscriber.State?
    ) async -> String? {
        guard let whisperKit, let processor else { return nil }

        let samples = Array(processor.audioSamples)
        guard samples.count >= Self.minFinalFlushSamples else { return nil }

        let confirmedSegments = state?.confirmedSegments ?? []
        let unconfirmedSegments = state?.unconfirmedSegments ?? []

        // How far (in samples) the realtime loop actually decoded — the end of
        // the last segment it produced, confirmed or not. Segment timestamps
        // are relative to the session buffer (we purge the processor at start).
        let decodedUpToSeconds = max(
            confirmedSegments.last.map { Double($0.end) } ?? 0,
            unconfirmedSegments.last.map { Double($0.end) } ?? 0
        )
        let decodedUpToIndex = min(
            samples.count,
            max(0, Int(decodedUpToSeconds * Double(Self.sampleRate)))
        )

        let tail = samples[decodedUpToIndex...]
        let tailSeconds = Double(tail.count) / Double(Self.sampleRate)
        let streamingText = state.map(Self.extractFinalText(from:)) ?? ""
        traceStream("flush: buffer=\(String(format: "%.1f", Double(samples.count) / Double(Self.sampleRate)))s undecoded=\(String(format: "%.2f", tailSeconds))s confirmed=\(confirmedSegments.count) unconfirmed=\(unconfirmedSegments.count)")

        // Fast path: the tail can't contain a word (too short) or is silence
        // (peak below speech level) — streaming text is complete, no decode.
        let tailPeak = tail.reduce(Float(0)) { max($0, abs($1)) }
        if tail.count < Self.minTailSamples || tailPeak < Self.tailSilencePeak {
            let cleaned = Self.stripNoiseTokens(from: streamingText)
            if !cleaned.isEmpty {
                traceStream("flush: fast path — tail \(String(format: "%.2f", tailSeconds))s peak \(String(format: "%.3f", tailPeak)), no decode")
                return cleaned
            }
        }

        // Tail flush: decode only the audio the realtime loop never saw and
        // append it to the streaming text. Cost: one Whisper window.
        do {
            traceStream("flush: tail decode of \(String(format: "%.2f", tailSeconds))s (peak \(String(format: "%.3f", tailPeak)))")
            let tailText = try await transcribeBuffer(
                Array(tail),
                with: whisperKit,
                options: activeDecodingOptions
            )
            let text = [streamingText, tailText]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let cleaned = Self.stripNoiseTokens(from: text)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            traceStream("flush: tail decode failed: \(error)")
            return nil
        }
    }

    /// Batch-transcribes a PCM buffer with the session's decoding options.
    private func transcribeBuffer(
        _ samples: [Float],
        with whisperKit: WhisperKit,
        options: DecodingOptions?
    ) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop streaming without returning a result (e.g., on cancel).
    public func cancelStreamTranscription() async {
        await streamTranscriber?.stopStreamTranscription()
        try? await sessionTask?.value
        activeProcessor?.purgeAudioSamples(keepingLast: 0)
        streamTranscriber = nil
        interimCallback = nil
        lastTranscriberState = nil
        finalTextEmitted = false
        activeProcessor = nil
        activeDecodingOptions = nil
        sessionTask = nil
    }

    // MARK: - State change handler

    /// Receives state changes from AudioStreamTranscriber on its executor thread,
    /// captures the state, and re-dispatches to this actor for processing.
    /// Named explicitly to clarify it does NOT run on MainActor.
    private nonisolated func enqueueStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        Task {
            await handleStateChange(oldState: oldState, newState: newState)
        }
    }

    private func handleStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        // Always capture the latest state for stopStreamTranscription() to read
        lastTranscriberState = newState

        // Extract confirmed text from confirmed segments
        let confirmed = newState.confirmedSegments
            .map(\.text)
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Unconfirmed text — prefer unconfirmedSegments if available
        let unconfirmed: String
        if !newState.unconfirmedSegments.isEmpty {
            unconfirmed = newState.unconfirmedSegments
                .map(\.text)
                .joined(separator: "")
        } else if !newState.unconfirmedText.isEmpty {
            unconfirmed = newState.unconfirmedText.joined()
        } else {
            unconfirmed = ""
        }

        // Detect if stream has ended (isRecording = false and we had text)
        let isFinal = !newState.isRecording && !(confirmed.isEmpty && unconfirmed.isEmpty)

        if isFinal {
            finalTextEmitted = true
        }

        let transcript = InterimTranscript(
            confirmed: confirmed,
            unconfirmed: unconfirmed,
            isFinal: isFinal
        )

        // Deliver to callback
        interimCallback?(transcript)
    }

    // MARK: - Helpers

    /// Extracts final text from a completed AudioStreamTranscriber.State.
    static func extractFinalText(from state: AudioStreamTranscriber.State) -> String {
        extractTextFromSegments(confirmed: state.confirmedSegments, unconfirmed: state.unconfirmedSegments)
    }

    /// Extracts and trims text from confirmed and unconfirmed segment arrays.
    /// Separated for testability without requiring WhisperKit State construction.
    static func extractTextFromSegments(
        confirmed: [TranscriptionSegment],
        unconfirmed: [TranscriptionSegment]
    ) -> String {
        let confirmedText = confirmed.map(\.text).joined(separator: "")
        let unconfirmedText = unconfirmed.map(\.text).joined(separator: "")

        let parts = [confirmedText, unconfirmedText].filter { !$0.isEmpty }
        return parts.joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases Whisper hallucinates on silence (trained-in YouTube outros etc).
    /// Only treated as noise when the ENTIRE transcript consists of them — a real
    /// dictation that starts "Okay." or ends "Thank you." must never lose words.
    private static let hallucinationPhrases = [
        "Waiting for speech",
        "Thank you.", "Thanks for watching!", "Subscribe!",
        "Bye.", "Bye!", "Thank you for watching.",
        "The end.", "See you next time.", "Okay."
    ]

    /// Strips Whisper special tokens and hallucinated noise from transcribed text.
    static func stripNoiseTokens(from text: String) -> String {
        // Strip Whisper special tokens: <|startoftranscript|>, <|en|>, <|0.00|>, etc.
        var result = text.replacingOccurrences(
            of: "<\\|[^|]+\\|>",
            with: "",
            options: .regularExpression
        )

        // Strip bracketed/parenthesised sound annotations: [BLANK_AUDIO], [ Silence ],
        // [typing], (keyboard clicking), (clears throat). Dictated speech cannot
        // produce literal brackets, so these are always Whisper noise annotations.
        result = result.replacingOccurrences(
            of: "\\[[^\\]]*\\]|\\([a-z_ ]+\\)",
            with: " ",
            options: .regularExpression
        )

        // Whisper emits runs of periods ("..", "...") when audio cuts off mid-speech.
        // Replace with a space — not empty — so surrounding words don't fuse together.
        result = result.replacingOccurrences(of: "\\.{2,}", with: " ", options: .regularExpression)

        // Collapse whitespace introduced by the removals above.
        result = result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop the transcript only when it consists entirely of hallucination
        // phrases; never delete them from within real speech.
        var probe = result
        for phrase in Self.hallucinationPhrases {
            probe = probe.replacingOccurrences(of: phrase, with: " ")
        }
        if probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }

        return result
    }
}
