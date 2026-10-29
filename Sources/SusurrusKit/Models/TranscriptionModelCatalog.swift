import Foundation

/// The transcription models the app offers. Parakeet does the final
/// transcription; Whisper Small runs the live preview (and is the
/// Whisper-only choice). The larger Whisper models were dropped once
/// Parakeet with pause trimming beat them on the user's voice (2026-10-28).
public enum TranscriptionModelCatalog {
    public static let defaultModel = ParakeetTranscriber.Variant.v2.rawValue

    public static let supported: [String] =
        ParakeetTranscriber.Variant.allCases.map(\.rawValue) + [ParakeetTranscriber.previewWhisperModel]

    public static func isSupported(_ model: String) -> Bool {
        supported.contains(model)
    }
}
