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

    /// Peak amplitude below which the buffer is considered silence and the
    /// final decode is skipped.
    private static let tailSilencePeak: Float = 0.015

    /// Hard cap on vocabulary prompt tokens. Prompt tokens are prefilled
    /// SEQUENTIALLY through the decoder on every decode, so an uncapped
    /// vocabulary (hundreds of tokens) adds seconds of constant overhead
    /// per pass regardless of model size.
    private static let maxPromptTokens = 48

    /// Transcription language. Fixed (not nil) because `language: nil` makes
    /// WhisperKit run a language-detection pass before EVERY decode — an extra
    /// encoder+decoder round trip of pure overhead for a dictation app.
    private var languageCode = "en"

    /// One second of speech-like multi-tone audio for prewarm/keep-warm.
    /// Pure zeros get rejected by the energy check before reaching the
    /// encoder, which silently turns warming into a no-op.
    private static func warmupSamples() -> [Float] {
        let fundamentals: [Float] = [150, 300, 600, 1200]
        return (0..<sampleRate).map { i in
            let t = Float(i) / Float(sampleRate)
            return fundamentals.reduce(0) { acc, f in
                acc + 0.1 * sin(2.0 * .pi * f * t)
            }
        }
    }

    // MARK: - State

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var modelReady = false

    /// Vocabulary prompt applied to each decode session.
    /// Legacy fallback — superseded by `vocabularySelector` when set.
    private var vocabularyPrompt: String = ""

    /// Returns bias terms ranked most-relevant-first for a given preview
    /// text. Called at stop time so the final decode's prompt-token budget
    /// is spent on terms the session plausibly contains, instead of the
    /// first N vocabulary entries in list order.
    public typealias VocabularySelector = @Sendable (_ previewText: String) -> [String]
    private var vocabularySelector: VocabularySelector?

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

        let loadStart = Date()
        let kit = try await WhisperKit(modelFolder: modelFolder.path, computeOptions: computeOptions)
        traceStream("setupModel: '\(modelName)' loaded in \(msSince(loadStart))ms")

        // Prewarm: the FIRST inference on a freshly-loaded CoreML model pays a
        // one-time ANE compilation/specialisation cost (often 10-30s), and an
        // idle model can have its ANE context evicted. Run one decode of
        // speech-like audio now so that cost lands here — during "loading" —
        // instead of on the user's first real recording. Only flip modelReady
        // once the ANE path is hot.
        let warmStart = Date()
        _ = try? await kit.transcribe(
            audioArray: Self.warmupSamples(),
            decodeOptions: DecodingOptions(task: .transcribe, language: languageCode)
        )
        traceStream("setupModel: '\(modelName)' prewarmed in \(msSince(warmStart))ms")

        self.whisperKit = kit
        modelReady = true
    }

    /// Run a small inference to keep the model's ANE context resident. Call
    /// periodically while idle so the first recording after a lull doesn't pay
    /// the cold-start cost. No-op if the model isn't loaded.
    public func keepWarm() async {
        guard modelReady, let whisperKit else { return }
        let warmStart = Date()
        do {
            _ = try await whisperKit.transcribe(
                audioArray: Self.warmupSamples(),
                decodeOptions: DecodingOptions(task: .transcribe, language: languageCode)
            )
            // Routine warm decodes were 70% of the debug log. Only slow
            // ones carry signal — they mean the ANE context was evicted.
            let ms = msSince(warmStart)
            if ms > 300 {
                traceStream("keepWarm: slow decode in \(ms)ms — context was likely evicted")
            }
        } catch {
            traceStream("keepWarm: decode FAILED in \(msSince(warmStart))ms: \(error)")
        }
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
    /// Legacy path — ignored while a vocabulary selector is set.
    public func setVocabularyPrompt(_ prompt: String) {
        vocabularyPrompt = prompt
    }

    /// Set the relevance-ranked term selector for the final decode.
    public func setVocabularySelector(_ selector: @escaping VocabularySelector) {
        vocabularySelector = selector
    }

    /// Set the transcription language (ISO 639-1 code, e.g. "en").
    public func setLanguage(_ code: String) {
        languageCode = code
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

        // Streaming (preview) options: NO vocabulary prompt. Prompt tokens are
        // prefilled sequentially through the decoder on EVERY realtime pass —
        // an uncapped vocabulary makes each pass take seconds and the preview
        // fall hopelessly behind. The preview only feeds the overlay; the
        // final whole-buffer decode below carries the vocabulary bias.
        let options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )

        // Final-decode options: vocabulary prompt, hard-capped so prefill
        // stays bounded (~tens of ms, not seconds). When a selector is set,
        // this is recomputed at stop time from the preview text; the legacy
        // flat prompt here is the fallback.
        var finalOptions = options
        if vocabularySelector == nil, !vocabularyPrompt.isEmpty {
            let tokens = tokenizer.encode(text: vocabularyPrompt)
            finalOptions.promptTokens = Array(tokens.prefix(Self.maxPromptTokens))
            if tokens.count > Self.maxPromptTokens {
                traceStream("vocab prompt capped: \(tokens.count) -> \(Self.maxPromptTokens) tokens")
            }
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
        self.activeDecodingOptions = finalOptions

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

        // Cancel the in-flight decode pass instead of draining it — we're
        // about to batch-decode the whole buffer anyway, so its result is
        // redundant and waiting for it just serializes two decodes.
        sessionTask?.cancel()
        try? await sessionTask?.value
        traceStream("stop: loop cancelled+exited in \(msSince(stopStart))ms")

        let state = lastTranscriberState
        let processor = activeProcessor
        streamTranscriber = nil
        interimCallback = nil
        activeProcessor = nil
        sessionTask = nil

        // Spend the prompt-token budget on relevance-ranked terms before
        // the final decode.
        composeStopTimePromptTokens(state: state)

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

    /// Recomputes the final decode's prompt tokens from the streaming
    /// preview text via the vocabulary selector. Terms are packed in rank
    /// order until the budget is exhausted (a term that doesn't fit is
    /// skipped, not truncated mid-token).
    private func composeStopTimePromptTokens(state: AudioStreamTranscriber.State?) {
        guard let selector = vocabularySelector,
              let tokenizer = whisperKit?.tokenizer,
              activeDecodingOptions != nil else { return }

        let preview = state.map { Self.extractFinalText(from: $0) } ?? ""
        let terms = selector(preview)
        guard !terms.isEmpty else {
            activeDecodingOptions?.promptTokens = nil
            return
        }

        var chosen: [String] = []
        var tokens: [Int] = []
        for term in terms {
            let candidate = (chosen + [term]).joined(separator: ", ")
            let encoded = tokenizer.encode(text: candidate)
            if encoded.count > Self.maxPromptTokens { continue }
            chosen.append(term)
            tokens = encoded
        }
        activeDecodingOptions?.promptTokens = tokens.isEmpty ? nil : tokens
        traceStream("stop: prompt \(tokens.count)/\(Self.maxPromptTokens) tokens, \(chosen.count)/\(terms.count) terms: \(chosen.joined(separator: ", "))")
    }

    /// Produces the final transcript with ONE whole-buffer batch decode.
    ///
    /// The streaming loop's per-pass state proved unreliable for finalization
    /// (segment end timestamps lag far behind the buffer), and Whisper's cost
    /// for clips ≤30s is one fixed window decode regardless of length — so
    /// decoding "only the tail" saves nothing and risks losing words. The
    /// in-flight streaming pass is cancelled before this runs, so this is the
    /// only decode on the ANE at stop time.
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

        let bufferSeconds = Double(samples.count) / Double(Self.sampleRate)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        traceStream("flush: whole-buffer decode of \(String(format: "%.1f", bufferSeconds))s (peak \(String(format: "%.3f", peak)))")

        // Whole-buffer silence — nothing to transcribe.
        guard peak >= Self.tailSilencePeak else { return nil }

        do {
            let text = try await transcribeBuffer(
                samples,
                with: whisperKit,
                options: activeDecodingOptions
            )
            let cleaned = Self.stripNoiseTokens(from: text)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            traceStream("flush: decode failed: \(error)")
            return nil
        }
    }

    /// Debug preference: when set, the final decode also computes per-word
    /// probabilities (costs extra alignment time) and logs them, so we can
    /// measure whether low confidence predicts the words users actually fix
    /// before building any UI on it.
    public static let confidenceLoggingKey = "confidenceLogging"

    /// Batch-transcribes a PCM buffer with the session's decoding options.
    private func transcribeBuffer(
        _ samples: [Float],
        with whisperKit: WhisperKit,
        options: DecodingOptions?
    ) async throws -> String {
        guard !samples.isEmpty else { return "" }

        var effectiveOptions = options ?? DecodingOptions(task: .transcribe)
        let logConfidence = UserDefaults.standard.bool(forKey: Self.confidenceLoggingKey)
        if logConfidence {
            effectiveOptions.wordTimestamps = true
        }

        let decodeStart = Date()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: effectiveOptions
        )
        traceStream("decode: \(String(format: "%.1f", Double(samples.count) / Double(Self.sampleRate)))s audio in \(msSince(decodeStart))ms (promptTokens=\(effectiveOptions.promptTokens?.count ?? 0), wordTimestamps=\(logConfidence))")

        if logConfidence {
            let words = results.flatMap(\.segments).compactMap(\.words).flatMap { $0 }
            if !words.isEmpty {
                let line = words
                    .map { "[\(String(format: "%.2f", $0.probability))]\($0.word.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: " ")
                let mean = words.map(\.probability).reduce(0, +) / Float(words.count)
                traceStream("confidence: mean=\(String(format: "%.2f", mean)) \(line)")
            }
        }

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
