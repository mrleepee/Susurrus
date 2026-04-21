import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Streaming transcription service using WhisperKit's AudioStreamTranscriber.
/// Manages a live audio pipeline and delivers interim transcripts via callback.
public actor StreamingTranscriptionService {

    // MARK: - Types

    /// Callback type for delivering interim transcripts.
    /// Fired on the AudioStreamTranscriber's executor; re-dispatched to this actor.
    public typealias InterimCallback = @Sendable (InterimTranscript) -> Void

    // MARK: - State

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var modelReady = false

    /// Vocabulary prompt applied to each decode session.
    private var vocabularyPrompt: String = ""

    /// Callback invoked on each interim transcript update.
    private var interimCallback: InterimCallback?

    /// The last observed state from the transcriber's callback.
    /// Used by stopStreamTranscription() to return the final transcript
    /// without polling or sleeping.
    private var lastTranscriberState: AudioStreamTranscriber.State?

    /// Tracks whether the stream has emitted a final transcript.
    private var finalTextEmitted = false

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
    /// - Parameter callback: Called on each state change with confirmed/unconfirmed text.
    /// - Throws: `TranscriptionError.modelNotReady` if the model is not loaded.
    public func startStreamTranscription(callback: @escaping InterimCallback) async throws {
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

        // AudioStreamTranscriber requires components extracted from WhisperKit
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
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
        try await transcriber.startStreamTranscription()
    }

    /// Stop streaming transcription and return the final transcript.
    /// - Returns: The final confirmed text, or throws if no speech was detected.
    public func stopStreamTranscription() async throws -> String {
        guard let transcriber = streamTranscriber else {
            return ""
        }

        // Stop audio capture. NOTE: AudioStreamTranscriber.stopStreamTranscription()
        // sets isRecording=false and stops recording immediately. The realtimeLoop
        // exits on its next iteration WITHOUT processing any buffered audio that
        // arrived since the last transcribe cycle. Therefore we cannot rely on
        // subsequent callbacks to deliver the final text — we must harvest
        // whatever state the callback has already captured.
        await transcriber.stopStreamTranscription()

        // Yield briefly so any in-flight stateChangeCallback dispatched via
        // enqueueStateChange (which wraps handleStateChange in Task {}) can
        // execute on this actor before we read lastTranscriberState.
        try? await Task.sleep(for: .milliseconds(50))

        // Read the final state captured via callback.
        let state = lastTranscriberState
        streamTranscriber = nil
        interimCallback = nil

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

    /// Stop streaming without returning a result (e.g., on cancel).
    public func cancelStreamTranscription() async {
        await streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
        interimCallback = nil
        lastTranscriberState = nil
        finalTextEmitted = false
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

    /// Strips Whisper special tokens and hallucinated noise from transcribed text.
    static func stripNoiseTokens(from text: String) -> String {
        // Strip Whisper special tokens: <|startoftranscript|>, <|en|>, <|transcribe|>, <|0.00|>, etc.
        var result = text.replacingOccurrences(
            of: "<\\|[^|]+\\|>",
            with: "",
            options: .regularExpression
        )
        // Strip Whisper ellipsis token that appears as literal "..." when audio is cut off mid-speech
        result = result.replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
        let noiseTokens = [
            "Waiting for speech", "[BLANK_AUDIO]", "[NO_SPEECH]", "(blank_audio)",
            "Thank you.", "Thanks for watching!", "Subscribe!",
            "Bye.", "Bye!", "Thank you for watching.",
            "The end.", "See you next time.", "Okay."
        ]
        for token in noiseTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
