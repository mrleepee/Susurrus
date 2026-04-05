/// Protocol for managing a custom vocabulary list that biases transcription.
public protocol VocabularyManaging: Sendable {
    /// Get the current vocabulary words.
    func vocabularyWords() -> [String]

    /// Set the vocabulary words.
    func setVocabularyWords(_ words: [String])

    /// Get the words joined as a prompt string for WhisperKit.
    func promptString() -> String

    /// Get a context string describing vocabulary terms with categories for LLM prompt injection.
    /// Returns an empty string if vocabulary is empty or not categorized.
    func llmContextString() -> String
}

/// Errors during vocabulary management.
public enum VocabularyError: Error, Sendable, Equatable {
    case wordTooLong(String)
    case tooManyWords(Int)
}
