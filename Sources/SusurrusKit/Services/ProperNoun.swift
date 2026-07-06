import Foundation

/// Heuristic for words worth learning as vocabulary: CamelCase, ALLCAPS,
/// or Capitalized-and-uncommon. Shared by notebook bias-term extraction
/// and correction-driven vocabulary promotion.
enum ProperNoun {
    /// Sentence-initial words are capitalized by convention, so the
    /// capitalized-and-uncommon signal is meaningless there — only
    /// CamelCase/ALLCAPS count in that position.
    static func looksLikeProperNoun(_ word: String, isSentenceInitial: Bool = false) -> Bool {
        let letters = word.filter(\.isLetter)
        guard let first = word.first, letters.count >= 2 else { return false }

        // ALLCAPS acronym
        if letters.allSatisfy(\.isUppercase) { return true }
        // CamelCase: lowercase→uppercase transition inside the word
        var previous: Character?
        for ch in word {
            if let p = previous, p.isLowercase, ch.isUppercase { return true }
            previous = ch
        }
        // Capitalized and not a common English word
        if !isSentenceInitial, first.isUppercase, !CommonWords.contains(word.lowercased()) {
            return true
        }
        return false
    }

    /// Category guess for a promoted word.
    static func guessCategory(_ word: String) -> VocabularyCategory {
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return .acronym }
        return .custom
    }
}
