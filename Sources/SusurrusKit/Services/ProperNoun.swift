import Foundation

/// Heuristic for words worth learning as vocabulary: CamelCase, ALLCAPS,
/// or Capitalized-and-uncommon. Shared by history bias-term extraction
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
    /// Shared by history bias-term extraction.
    ///
    /// Results are ordered by how many of `texts` contain the term, most
    /// repeated first. The prompt budget fits roughly 14 of 55 candidates, so
    /// ordering decides what actually reaches Whisper, and a term said once is
    /// the weakest evidence there is that it will be said again. Production
    /// data, 2026-08-05: `Iceberg` and `IDs` each appeared in **zero** of the
    /// last 30 dictations yet held prompt slots, and Whisper duly inserted both
    /// into a dictation where neither was spoken. Meanwhile `MarkLogic` (5 of
    /// 30), `Starrocks` (3) and `Silvia` (3) are the terms worth spending the
    /// budget on.
    ///
    /// Ties break on first appearance, so packing stays reproducible for
    /// identical input.
    ///
    /// `excluding` rejects a candidate after every other test has passed. It
    /// exists so callers can drop ordinary words the user writes in lowercase
    /// without this type needing to know about casing profiles or dictionaries.
    /// The default admits everything, preserving the original behaviour.
    static func extractBiasTerms(
        from texts: [String],
        limit: Int,
        excluding isExcluded: (String) -> Bool = { _ in false }
    ) -> [String] {
        /// First-seen spelling, order of first appearance, and the number of
        /// distinct texts the term appears in.
        var display: [String: String] = [:]
        var order: [String: Int] = [:]
        var documentCount: [String: Int] = [:]

        for text in texts {
            // Per text, not per sentence: a term repeated three times in one
            // dictation is one piece of evidence, not three.
            var seenInThisText: Set<String> = []
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
                    let term = String(word)
                    guard term.count >= 3 else { continue }
                    let lowered = term.lowercased()
                    if isAllCaps(term), sentenceIsShouted || CommonWords.contains(lowered) { continue }
                    guard looksLikeProperNoun(term, isSentenceInitial: index == 0) else { continue }
                    guard !isExcluded(term) else { continue }
                    guard seenInThisText.insert(lowered).inserted else { continue }
                    if display[lowered] == nil {
                        display[lowered] = term
                        order[lowered] = order.count
                    }
                    documentCount[lowered, default: 0] += 1
                }
            }
        }

        return documentCount.keys
            .sorted { a, b in
                let ca = documentCount[a] ?? 0
                let cb = documentCount[b] ?? 0
                if ca != cb { return ca > cb }
                return (order[a] ?? 0) < (order[b] ?? 0)
            }
            .prefix(limit)
            .compactMap { display[$0] }
    }

    static func isAllCaps(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// The rule that keeps ordinary English out of the ASR bias prompt, for
    /// passing to `extractBiasTerms(from:limit:excluding:)`.
    ///
    /// A candidate is rejected only when all three hold: it is not an acronym,
    /// it exists in the system dictionary, and the user's own prose writes it
    /// in lowercase. All three are needed.
    ///
    /// - Dictionary alone is unusable: macOS ships `web2`, which contains given
    ///   names, and testing it alone rejected 11 of 20 real names in production
    ///   data (`Rajesh`, `Julia`, `Elizabeth`, `Paul`…).
    /// - Casing evidence alone is too weak on rare words, which have no record.
    /// - The ALL-CAPS exemption matters because `web2` also contains `dom`,
    ///   `stem`, `uri` and `mrs`; without it, writing "stem" once in prose would
    ///   knock the acronym `STEM` out of the prompt. The acronym and the noun
    ///   are not the same word.
    static func ordinaryWordExclusion(
        profile: CasingProfile,
        dictionary: EnglishDictionary
    ) -> (String) -> Bool {
        { word in
            !isAllCaps(word)
                && dictionary.contains(word)
                && profile.writesInLowercase(word)
        }
    }
}
