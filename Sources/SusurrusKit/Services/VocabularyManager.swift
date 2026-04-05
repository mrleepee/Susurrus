import Foundation

/// Concrete vocabulary manager persisting to UserDefaults.
public final class VocabularyManager: VocabularyManaging, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "vocabularyWords"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Factory for testing with an isolated UserDefaults suite.
    public static func createForTesting() -> VocabularyManager {
        VocabularyManager(defaults: UserDefaults(suiteName: "com.susurrus.vocab.test.\(UUID().uuidString)")!)
    }

    public func vocabularyWords() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func setVocabularyWords(_ words: [String]) {
        defaults.set(words, forKey: key)
    }

    public func promptString() -> String {
        vocabularyWords().joined(separator: ", ")
    }

    public func llmContextString() -> String {
        // Flat vocabulary has no category context — return empty string.
        // F9 will override this with category-annotated entries.
        ""
    }
}
