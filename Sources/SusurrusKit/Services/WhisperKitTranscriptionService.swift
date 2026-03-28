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

    /// Whether the model is loaded and ready for transcription.
    public func isModelReady() -> Bool {
        modelReady
    }

    /// Download (if needed) and load the WhisperKit model.
    /// Uses WhisperKit's default cache location (~/.cache/huggingface/hub/).
    public func setupModel(
        modelName: String = "base",
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

        // Load from the downloaded location
        let kit = try await WhisperKit(modelFolder: modelFolder.path)
        self.whisperKit = kit
        modelReady = true
    }

    /// Transcribe audio buffer using WhisperKit.
    public func transcribe(audio: [Float]) async throws -> String {
        guard modelReady, let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        var promptTokens: [Int]? = nil
        if !vocabularyPrompt.isEmpty,
           let tokenizer = whisperKit.tokenizer {
            promptTokens = tokenizer.encode(text: vocabularyPrompt)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            promptTokens: promptTokens
        )

        let transcriptionResult = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )

        guard let firstResult = transcriptionResult.first else {
            throw TranscriptionError.transcriptionFailed("No result returned")
        }

        var text = firstResult.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // WhisperKit may emit special tokens like [BLANK_AUDIO] — strip them
        let noiseTokens = ["[BLANK_AUDIO]", "[NO_SPEECH]", "(blank_audio)"]
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
