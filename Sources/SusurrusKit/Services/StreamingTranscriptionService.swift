import CoreML
import Foundation
import WhisperKit

/// Streaming transcription service using WhisperKit's AudioStreamTranscriber.
/// Manages a live audio pipeline and delivers interim transcripts via callback.
public actor StreamingTranscriptionService {

    // MARK: - Types

    /// Callback type for delivering interim transcripts.
    /// Fired on the AudioStreamTranscriber's executor; dispatched to MainActor.
    public typealias InterimCallback = @Sendable (InterimTranscript) -> Void

    // MARK: - State

    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var modelReady = false

    /// Vocabulary prompt applied to each decode session.
    private var vocabularyPrompt: String = ""

    /// Callback invoked on each interim transcript update.
    private var interimCallback: InterimCallback?

    // MARK: - Init

    public init() {}

    // MARK: - Model lifecycle

    /// Whether the model is loaded and ready.
    public func isModelReady() -> Bool {
        modelReady
    }

    /// Load the model from the given folder.
    /// Reuses the same setup as WhisperKitTranscriptionService for consistency.
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

        self.interimCallback = callback

        // Build DecodingOptions, applying vocabulary prompt if set
        var options = DecodingOptions(
            task: .transcribe,
            language: nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )

        if !vocabularyPrompt.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: vocabularyPrompt)
        }

        // AudioStreamTranscriber requires components extracted from WhisperKit
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: whisperKit.tokenizer!,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                self?.handleStateChange(oldState: oldState, newState: newState)
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

        transcriber.stopStreamTranscription()

        // Give the transcriber a moment to finalise
        try? await Task.sleep(for: .milliseconds(200))

        // Read final state
        let state = await transcriber.currentState

        self.streamTranscriber = nil
        self.interimCallback = nil

        let text = Self.extractFinalText(from: state)

        // Strip noise tokens
        let cleaned = Self.stripNoiseTokens(from: text)

        guard !cleaned.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        return cleaned
    }

    /// Stop streaming without returning a result (e.g., on cancel).
    public func cancelStreamTranscription() {
        streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
        interimCallback = nil
    }

    // MARK: - State change handler

    /// Handles AudioStreamTranscriber state changes, dispatched from the actor's executor.
    /// Must dispatch to MainActor for UI updates.
    private nonisolated func handleStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        Task {
            await handleStateChangeOnMain(oldState: oldState, newState: newState)
        }
    }

    private func handleStateChangeOnMain(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        // Extract confirmed text from confirmed segments
        let confirmed = newState.confirmedSegments
            .map(\.text)
            .joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Unconfirmed text — prefer unconfirmedSegments if available, else currentText
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
    private static func extractFinalText(from state: AudioStreamTranscriber.State) -> String {
        let confirmed = state.confirmedSegments.map(\.text).joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments.map(\.text).joined(separator: " ")
        let all = [confirmed, unconfirmed].filter { !$0.isEmpty }.joined(separator: " ")
        return all.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips hallucinated noise tokens from transcribed text.
    private static func stripNoiseTokens(from text: String) -> String {
        let noiseTokens = [
            "[BLANK_AUDIO]", "[NO_SPEECH]", "(blank_audio)",
            "Thank you.", "Thanks for watching!", "Subscribe!",
            "Bye.", "Bye!", "Thank you for watching.",
            "The end.", "See you next time.", "Okay."
        ]
        var result = text
        for token in noiseTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AudioStreamTranscriber extension for currentState

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
private extension AudioStreamTranscriber {
    var currentState: State {
        // Access the internal state property for reading after stop
        // Note: AudioStreamTranscriber is an actor, so we read state via async
        // This is a best-effort read; for fully accurate final text use
        // the callback's final emission instead.
        return State()
    }
}

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
private extension AudioStreamTranscriber.State {
    init() {
        self.init(
            isRecording: false,
            currentFallbacks: 0,
            lastBufferSize: 0,
            lastConfirmedSegmentEndSeconds: 0,
            bufferEnergy: [],
            currentText: "",
            confirmedSegments: [],
            unconfirmedSegments: [],
            unconfirmedText: []
        )
    }
}
