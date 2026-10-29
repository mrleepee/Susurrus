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
    /// When set, the stop-time decode uses Parakeet; Whisper still drives
    /// capture and the live preview, and is the fallback if Parakeet fails.
    private var parakeet: ParakeetTranscriber?
    private var modelReady = false

    /// Stop-time decode settings. Always `.production` in the app; the eval
    /// harness overrides it to compare configurations.
    private var finalConfig = FinalDecodeConfig.production

    /// Whether to write to ~/susurrus_debug.log. The eval harness turns this
    /// off so batch runs don't flood the user's log.
    private var tracingEnabled = true

    private func trace(_ message: String) {
        if tracingEnabled { traceStream(message) }
    }

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

    /// Folder name of the loaded model, recorded with captured clips.
    private var loadedModelName = ""

    /// When set, the next stop keeps a copy of the session audio for
    /// `takeRetainedSession()` (the opt-in accuracy-testing capture).
    private var retainSessionAudio = false
    private var retainedSession: RetainedSession?

    /// A stopped session's audio and what the stop-time decode made of it,
    /// handed out before the session buffer is purged.
    public struct RetainedSession: Sendable {
        /// The whole 16 kHz mono session buffer.
        public let samples: [Float]
        /// The text `stopStreamTranscription` returned (raw ASR).
        public let rawText: String
        /// Bias terms packed into the final decode's prompt.
        public let promptTerms: [String]
        public let model: String
    }

    // MARK: - Init

    public init() {}

    // MARK: - Model lifecycle

    /// Whether the model is loaded and ready.
    public func isModelReady() -> Bool {
        modelReady
    }

    /// Load the model from the given folder.
    public func setupModel(
        modelName: String = "small",
        computeOptions: ModelComputeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        ),
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let parakeetVariant = ParakeetTranscriber.Variant(rawValue: modelName)
        let whisperModel = parakeetVariant == nil ? modelName : ParakeetTranscriber.previewWhisperModel
        let downloadBase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Susurrus")

        let modelFolder = try await WhisperKit.download(
            variant: whisperModel,
            downloadBase: downloadBase,
            progressCallback: { progress in
                guard progress.totalUnitCount > 0 else { return }
                let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                onDownloadProgress?(fraction)
            }
        )

        try await setupModel(modelFolder: modelFolder.path, computeOptions: computeOptions)
        if let parakeetVariant {
            try await enableParakeet(parakeetVariant, onDownloadProgress: onDownloadProgress)
        }
    }

    /// Switch the stop-time decode to Parakeet (loads it on first use).
    /// Call after a Whisper model is set up; the eval harness calls it
    /// directly after `setupModel(modelFolder:)`.
    public func enableParakeet(
        _ variant: ParakeetTranscriber.Variant = .v2,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let loadStart = Date()
        let engine = ParakeetTranscriber(variant: variant)
        try await engine.load(onDownloadProgress: onDownloadProgress)
        parakeet = engine
        loadedModelName = variant.modelFolderName
        trace("setupModel: \(variant.modelFolderName) loaded and prewarmed in \(msSince(loadStart))ms; final decode uses Parakeet")
    }

    /// Load and prewarm a model from a local folder, skipping the download
    /// step. The eval harness uses this to point at a model on disk.
    public func setupModel(
        modelFolder: String,
        computeOptions: ModelComputeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
    ) async throws {
        let modelName = URL(fileURLWithPath: modelFolder).lastPathComponent
        parakeet = nil
        let loadStart = Date()
        let kit = try await WhisperKit(modelFolder: modelFolder, computeOptions: computeOptions)
        trace("setupModel: '\(modelName)' loaded in \(msSince(loadStart))ms")

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
        trace("setupModel: '\(modelName)' prewarmed in \(msSince(warmStart))ms")

        self.whisperKit = kit
        loadedModelName = modelName
        // Per-model stop-time settings; the eval harness overrides this
        // afterwards with setFinalDecodeConfig.
        finalConfig = .production(forModel: modelName)
        trace("setupModel: final decode prompt budget \(finalConfig.maxPromptTokens) tokens")
        modelReady = true
    }

    /// Run a small inference to keep the model's ANE context resident. Call
    /// periodically while idle so the first recording after a lull doesn't pay
    /// the cold-start cost. No-op if the model isn't loaded.
    public func keepWarm() async {
        guard modelReady, let whisperKit else { return }
        let warmStart = Date()
        if let parakeet {
            _ = try? await parakeet.transcribe(samples: Self.warmupSamples())
        }
        do {
            _ = try await whisperKit.transcribe(
                audioArray: Self.warmupSamples(),
                decodeOptions: DecodingOptions(task: .transcribe, language: languageCode)
            )
            // Routine warm decodes were 70% of the debug log. Only slow
            // ones carry signal — they mean the ANE context was evicted.
            let ms = msSince(warmStart)
            if ms > 300 {
                trace("keepWarm: slow decode in \(ms)ms — context was likely evicted")
            }
        } catch {
            trace("keepWarm: decode FAILED in \(msSince(warmStart))ms: \(error)")
        }
    }

    /// Unload the model and stop any active stream.
    public func unloadModel() {
        streamTranscriber = nil
        whisperKit = nil
        parakeet = nil
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

    /// Override the stop-time decode settings (eval harness only).
    public func setFinalDecodeConfig(_ config: FinalDecodeConfig) {
        finalConfig = config
    }

    /// Enable or disable debug-log tracing (eval harness turns it off).
    /// Whether the next `stopStreamTranscription` keeps the session audio
    /// for `takeRetainedSession()`. Off unless the user opted in to keeping
    /// recordings; the app sets it before every stop.
    public func setRetainSessionAudio(_ enabled: Bool) {
        retainSessionAudio = enabled
        if !enabled { retainedSession = nil }
    }

    /// The last stopped session's audio, if it was retained. Hands it out
    /// once: a second call returns nil.
    public func takeRetainedSession() -> RetainedSession? {
        defer { retainedSession = nil }
        return retainedSession
    }

    public func setTracing(_ enabled: Bool) {
        tracingEnabled = enabled
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
        let options = previewOptions()

        // Final-decode options: vocabulary prompt, hard-capped so prefill
        // stays bounded (~tens of ms, not seconds). When a selector is set,
        // this is recomputed at stop time from the preview text; the legacy
        // flat prompt here is the fallback.
        let finalOptions = baseFinalOptions(tokenizer: tokenizer)

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
        retainedSession = nil

        // Stop audio capture; the realtime loop exits after its in-flight pass.
        await transcriber.stopStreamTranscription()

        // Cancel the in-flight decode pass instead of draining it — we're
        // about to batch-decode the whole buffer anyway, so its result is
        // redundant and waiting for it just serializes two decodes.
        sessionTask?.cancel()
        try? await sessionTask?.value
        trace("stop: loop cancelled+exited in \(msSince(stopStart))ms")

        let state = lastTranscriberState
        let processor = activeProcessor
        streamTranscriber = nil
        interimCallback = nil
        activeProcessor = nil
        sessionTask = nil

        // Final flush over the session buffer: one whole-buffer decode with
        // the prompt-token budget spent on terms ranked against the preview.
        let flushStart = Date()
        let samples = processor.map { Array($0.audioSamples) } ?? []
        var promptTerms: [String] = []
        if processor != nil, let baseOptions = activeDecodingOptions {
            let preview = state.map { Self.extractFinalText(from: $0) } ?? ""
            let final = await finalDecode(
                samples: samples,
                previewText: preview,
                baseOptions: baseOptions
            )
            promptTerms = final.promptTerms
            if final.outcome == .decoded {
                trace("stop: flush done in \(msSince(flushStart))ms, total \(msSince(stopStart))ms")
                processor?.purgeAudioSamples(keepingLast: 0)
                retain(samples: samples, text: final.text, promptTerms: promptTerms)
                return final.text
            }
        }
        trace("stop: flush produced nothing after \(msSince(flushStart))ms — falling back to streaming state")

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

        retain(samples: samples, text: cleaned, promptTerms: promptTerms)
        return cleaned
    }

    private func retain(samples: [Float], text: String, promptTerms: [String]) {
        guard retainSessionAudio, !samples.isEmpty else { return }
        retainedSession = RetainedSession(
            samples: samples, rawText: text, promptTerms: promptTerms, model: loadedModelName
        )
    }

    /// Streaming (preview) options: NO vocabulary prompt. Prompt tokens are
    /// prefilled sequentially through the decoder on EVERY realtime pass, so
    /// a prompt makes each pass slower and the preview falls behind. The
    /// preview only feeds the overlay and the stop-time term ranking.
    private func previewOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: languageCode,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
    }

    /// Final-decode options before stop-time prompt composition. Carries the
    /// legacy flat vocabulary prompt only when no selector is set.
    private func baseFinalOptions(tokenizer: any WhisperTokenizer) -> DecodingOptions {
        var options = finalConfig.decodingOptions(language: languageCode)
        if vocabularySelector == nil, !vocabularyPrompt.isEmpty {
            let tokens = tokenizer.encode(text: vocabularyPrompt)
            let kept = Array(tokens.prefix(finalConfig.maxPromptTokens))
            options.promptTokens = kept.isEmpty ? nil : kept
            if tokens.count > finalConfig.maxPromptTokens {
                trace("vocab prompt capped: \(tokens.count) -> \(finalConfig.maxPromptTokens) tokens")
            }
        }
        return options
    }

    /// The stop-time decode, shared by the app's stop path and
    /// `transcribeOffline`. Recomputes prompt tokens from `previewText` via
    /// the vocabulary selector, packing terms in rank order until the budget
    /// is exhausted, then runs ONE whole-buffer batch decode.
    ///
    /// The streaming loop's per-pass state proved unreliable for finalization
    /// (segment end timestamps lag far behind the buffer), and Whisper's cost
    /// for clips ≤30s is one fixed window decode regardless of length — so
    /// decoding "only the tail" saves nothing and risks losing words. The
    /// in-flight streaming pass is cancelled before this runs, so this is the
    /// only decode on the ANE at stop time.
    private func finalDecode(
        samples: [Float],
        previewText: String,
        baseOptions: DecodingOptions
    ) async -> FinalTranscript {
        guard let whisperKit else { return .skipped(.failed) }

        if let parakeet {
            let result = await parakeetDecode(samples: samples, engine: parakeet)
            if result.outcome != .failed { return result }
            trace("stop: Parakeet failed (\(result.failure ?? "?")) — falling back to Whisper")
        }

        var options = baseOptions
        var chosen: [String] = []
        if let selector = vocabularySelector, let tokenizer = whisperKit.tokenizer {
            let terms = selector(previewText)
            if terms.isEmpty {
                options.promptTokens = nil
            } else {
                let packed = FinalTranscriber.packPromptTokens(
                    terms: terms,
                    budget: finalConfig.maxPromptTokens,
                    encode: { tokenizer.encode(text: $0) }
                )
                options.promptTokens = packed.tokens.isEmpty ? nil : packed.tokens
                chosen = packed.chosen
                trace("stop: prompt \(packed.tokens.count)/\(finalConfig.maxPromptTokens) tokens, \(chosen.count)/\(terms.count) terms: \(chosen.joined(separator: ", "))")
            }
        }

        return await FinalTranscriber.decode(
            samples: samples,
            whisperKit: whisperKit,
            options: options,
            promptTerms: chosen,
            wordTimestamps: UserDefaults.standard.bool(forKey: Self.confidenceLoggingKey),
            trace: { [tracingEnabled] in if tracingEnabled { traceStream($0) } }
        )
    }

    /// The Parakeet stop-time decode, with the same too-short and silence
    /// guards as the Whisper path.
    private func parakeetDecode(samples: [Float], engine: ParakeetTranscriber) async -> FinalTranscript {
        guard samples.count >= FinalTranscriber.minSamples else { return .skipped(.tooShort) }
        let seconds = Double(samples.count) / 16_000
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        trace("flush: Parakeet decode of \(String(format: "%.1f", seconds))s (peak \(String(format: "%.3f", peak)))")
        guard peak >= FinalTranscriber.silencePeak else { return .skipped(.silent) }

        let start = Date()
        let text: String
        do {
            text = try await engine.transcribe(samples: samples)
        } catch {
            var failed = FinalTranscript.skipped(.failed)
            failed.failure = "\(error)"
            return failed
        }
        let ms = msSince(start)
        trace("decode: \(String(format: "%.1f", seconds))s audio in \(ms)ms (\(engine.variant.rawValue), pauses squeezed)")
        let cleaned = Self.stripNoiseTokens(from: text)
        return FinalTranscript(
            outcome: cleaned.isEmpty ? .empty : .decoded,
            text: cleaned,
            promptTerms: [],
            promptTokenCount: 0,
            segments: [],
            decodeMs: ms,
            failure: nil
        )
    }

    /// Debug preference: when set, the final decode also computes per-word
    /// probabilities (costs extra alignment time) and logs them, so we can
    /// measure whether low confidence predicts the words users actually fix
    /// before building any UI on it.
    public static let confidenceLoggingKey = "confidenceLogging"

    // MARK: - Offline transcription (eval harness)

    /// Runs the stop-time decode on a recorded buffer, exactly as
    /// `stopStreamTranscription` would for a live session whose preview
    /// produced `previewText`. Never touches an active session's state.
    public func transcribeOffline(samples: [Float], previewText: String) async throws -> FinalTranscript {
        guard modelReady, let whisperKit else { throw TranscriptionError.modelNotReady }
        guard let tokenizer = whisperKit.tokenizer else {
            throw TranscriptionError.transcriptionFailed("Tokenizer not available")
        }
        return await finalDecode(
            samples: samples,
            previewText: previewText,
            baseOptions: baseFinalOptions(tokenizer: tokenizer)
        )
    }

    /// A promptless whole-buffer decode with the streaming preview's options.
    /// Offline stand-in for the live preview text that feeds term ranking.
    public func previewTranscript(samples: [Float]) async throws -> String {
        guard modelReady, let whisperKit else { throw TranscriptionError.modelNotReady }
        guard samples.count >= FinalTranscriber.minSamples else { return "" }
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: previewOptions())
        return Self.stripNoiseTokens(from: results.map(\.text).joined(separator: " "))
    }

    /// Abandon the in-flight session with no output: no whole-buffer decode,
    /// nothing returned, nothing thrown. Used for a deliberate user cancel
    /// (Esc, wired in SusurrusApp.cancelActiveDictation) rather than a normal
    /// stop. Stopping the transcriber before touching `sessionTask` matters:
    /// it lets the realtime loop exit normally, so whichever caller is still
    /// blocked on `startStreamTranscription()`'s `task.value` returns without
    /// throwing, instead of surfacing a spurious "Recording failed"
    /// notification for what was actually a clean cancel.
    public func cancelStreamTranscription() async {
        await streamTranscriber?.stopStreamTranscription()
        try? await sessionTask?.value
        activeProcessor?.purgeAudioSamples(keepingLast: 0)
        retainedSession = nil
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
    /// Public so the app layer can clean the live interim stream for display —
    /// the final text is already cleaned here before it's returned.
    public static func stripNoiseTokens(from text: String) -> String {
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
