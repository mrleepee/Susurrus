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

    /// Extract proper-noun-ish bias terms from a batch of texts (newest
    /// first), deduplicated case-insensitively. Splits into sentences first
    /// so sentence-initial capitalization isn't mistaken for a proper noun.
    /// Shared by notebook and history bias-term extraction.
    static func extractBiasTerms(from texts: [String], limit: Int) -> [String] {
        var terms: [String] = []
        var seen: Set<String> = []
        outer: for text in texts {
            for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
                let words = sentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                // Whisper occasionally emits whole passages IN CAPITALS.
                // In a shouted sentence ALLCAPS is formatting, not acronym
                // evidence — production data showed "THE", "STATUTORY",
                // "TEST" packed into the prompt-token budget this way.
                let capsEligible = words.filter { $0.count >= 2 }
                let allCapsCount = capsEligible.filter { isAllCaps(String($0)) }.count
                let sentenceIsShouted = capsEligible.count >= 3
                    && allCapsCount * 3 > capsEligible.count * 2
                for (index, word) in words.enumerated() {
                    if terms.count >= limit { break outer }
                    let term = String(word)
                    guard term.count >= 3 else { continue }
                    let lowered = term.lowercased()
                    guard !seen.contains(lowered) else { continue }
                    if isAllCaps(term), sentenceIsShouted || CommonWords.contains(lowered) { continue }
                    guard looksLikeProperNoun(term, isSentenceInitial: index == 0) else { continue }
                    seen.insert(lowered)
                    terms.append(term)
                }
            }
        }
        return terms
    }

    private static func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }
}
