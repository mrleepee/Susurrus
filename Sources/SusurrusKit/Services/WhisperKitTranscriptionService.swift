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
    public func isModelReady() async -> Bool {
        modelReady
    }

    /// Load the WhisperKit model from a local folder. Call at app launch.
    public func loadModel(modelName: String = "large-v3", modelFolder: String? = nil) async throws {
        let kit = try await WhisperKit(model: modelName, modelFolder: modelFolder)
        self.whisperKit = kit
        modelReady = true
    }

    /// Full setup: download model if needed, then load it.
    /// Uses the provided model manager for download/cache decisions.
    public func setupModel(
        modelName: String = "large-v3",
        modelManager: ModelManaging,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let isCached = await modelManager.isModelCached(modelName: modelName)
        if !isCached {
            try await modelManager.downloadModel(modelName: modelName, onProgress: onDownloadProgress)
        }
        let cachePath = await modelManager.modelCachePath()
        try await loadModel(modelName: modelName, modelFolder: cachePath)
    }

    /// Transcribe audio buffer using WhisperKit.
    public func transcribe(audio: [Float]) async throws -> String {
        guard modelReady, let whisperKit else {
            throw TranscriptionError.modelNotReady
        }
        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: nil
        )

        let transcriptionResult = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options
        )

        guard let firstResult = transcriptionResult.first else {
            throw TranscriptionError.transcriptionFailed("No result returned")
        }

        let text = firstResult.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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
