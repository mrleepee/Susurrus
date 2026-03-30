import Foundation

/// Protocol for LLM-based text post-processing.
public protocol LLMProcessing: Sendable {
    /// Process raw transcription text through the LLM.
    /// Returns the cleaned/polished text, or throws on error.
    func process(text: String, systemPrompt: String) async throws -> String
}

/// Errors during LLM processing.
public enum LLMError: Error, Sendable, Equatable {
    case requestFailed(String)
    case invalidResponse
    case emptyResult
}
