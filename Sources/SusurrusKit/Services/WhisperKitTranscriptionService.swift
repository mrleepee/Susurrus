import CoreML
import Foundation
import WhisperKit

/// Concrete transcription service using WhisperKit for on-device inference.
/// Uses Metal-accelerated whisper on Apple Silicon.
public actor WhisperKitTranscriptionService: Transcribing {

    private nonisolated(unsafe) var whisperKit: WhisperKit?
    private var modelReady = false

    /// Optional custom vocabulary to bias transcription.
    public var vocabularyPrompt: String = ""

    public init() {}

    /// Set the vocabulary prompt (callable from outside the actor).
    public func setVocabularyPrompt(_ prompt: String) {
        vocabularyPrompt = prompt
    }

    /// Whether the model is loaded and ready for transcription.
    public func isModelReady() -> Bool {
        modelReady
    }

    /// Download (if needed) and load the WhisperKit model.
    /// Uses WhisperKit's default cache location (~/.cache/huggingface/hub/).
    public func setupModel(
        modelName: String = "base",
        computeOptions: ModelComputeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        ),
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // Download with progress tracking
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

        // Load from the downloaded location with the given compute options
        let kit = try await WhisperKit(modelFolder: modelFolder.path, computeOptions: computeOptions)
        self.whisperKit = kit
        modelReady = true
    }

    /// Transcribe audio buffer using WhisperKit.
    public func transcribe(audio: [Float]) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        return try await transcribe(audio: audio, decodeOptions: options)
    }

    /// Transcribe audio buffer using WhisperKit with custom decoding options.
    public func transcribe(audio: [Float], decodeOptions: DecodingOptions) async throws -> String {
        guard modelReady, let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        var options = decodeOptions
        if !vocabularyPrompt.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: vocabularyPrompt)
        }

        let transcriptionResult = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )

        guard let firstResult = transcriptionResult.first else {
            throw TranscriptionError.transcriptionFailed("No result returned")
        }

        var text = firstResult.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // WhisperKit may emit special tokens or hallucinate — strip them
        let noiseTokens = [
            "[BLANK_AUDIO]", "[NO_SPEECH]", "(blank_audio)",
            "Thank you.", "Thanks for watching!", "Subscribe!",
            "Bye.", "Bye!", "Thank you for watching.",
            "The end.", "See you next time.", "Okay."
        ]
        for token in noiseTokens {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        return text
    }

    /// Unload the model to free memory.
    public func unloadModel() {
        whisperKit = nil
        modelReady = false
    }
}
