import Foundation

/// Deterministic transcript corrector. Runs on every final transcript
/// (before any optional LLM pass) in three conceptual passes:
///
/// 1. **Learned rules** — exact n-gram replacements from past user edits.
/// 2. **Vocabulary matching** — exact-normalized hits ("mark logic" →
///    "MarkLogic", "sparql" → "SPARQL") and fuzzy phonetic hits
///    ("sparkle" → "SPARQL", "susurus" → "Susurrus").
/// 3. **Casing enforcement** — falls out of pass 2: any case-insensitive
///    vocab hit is rewritten to the stored casing (acronyms uppercased).
///
/// False-positive guard: single common English words (top-frequency list)
/// are never rewritten, so "person" can't become a vocab name like "Pearson".
/// Multi-word joins ("mark logic" → "marklogic") are exempt from the guard
/// when they normalize exactly to a vocab term — that collision is a strong
/// signal, not an accident.
public struct TranscriptCorrector: TranscriptCorrecting {

    /// Maximum n-gram window width, in words.
    private static let maxWindow = 3

    /// Fuzzy matches require at least this many alphanumeric characters
    /// on both sides — short words are too easy to false-positive.
    static let minFuzzyLength = 4

    /// Maximum normalized Damerau-Levenshtein distance ratio for a fuzzy hit.
    static let maxFuzzyRatio = 0.3

    /// Maximum absolute character-count difference for a fuzzy hit. Without
    /// this, a wide n-gram window can "swallow" a whole extra word: e.g.
    /// "the trust signals" (15 chars) sits within ratio 0.3 of "trustsignals"
    /// (12 chars) purely because the 3 deletions are cheap relative to the
    /// longer string. Fuzzy matching is for misspellings, not word-boundary
    /// slop, so the lengths must stay close.
    static let maxFuzzyLengthDiff = 2

    public init() {}

    // MARK: - Entry point

    public func correct(
        _ text: String,
        vocabulary: [VocabularyEntry],
        rules: [CorrectionRule]
    ) -> CorrectionOutcome {
        var changes: [CorrectionChange] = []
        var result = text

        if !rules.isEmpty {
            result = applyRules(to: result, rules: rules, changes: &changes)
        }
        if !vocabulary.isEmpty {
            result = applyVocabulary(to: result, vocabulary: vocabulary, changes: &changes)
        }

        return CorrectionOutcome(text: result, changes: changes)
    }

    // MARK: - Pass 1: learned rules

    private func applyRules(
        to text: String,
        rules: [CorrectionRule],
        changes: inout [CorrectionChange]
    ) -> String {
        let byMatch = Dictionary(
            rules.filter(\.enabled).map { ($0.match, $0) },
            uniquingKeysWith: { a, b in a.hitCount >= b.hitCount ? a : b }
        )
        guard !byMatch.isEmpty else { return text }

        let tokens = Self.wordTokens(in: text)
        var replacements: [Replacement] = []
        var claimed: [Range<Int>] = []

        for window in Self.windows(over: tokens, in: text) {
            guard !Self.overlapsAny(window.span, claimed) else { continue }
            let key = window.words.joined(separator: " ").lowercased()
            guard let rule = byMatch[key] else { continue }

            let original = String(text[window.range])
            var replacement = rule.replacement
            // Preserve sentence-initial capitalization, but only when the
            // replacement carries no intentional casing of its own.
            if replacement == replacement.lowercased(),
               let first = original.first, first.isUppercase {
                replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
            }
            guard replacement != original else { continue }

            replacements.append(Replacement(range: window.range, span: window.span, text: replacement))
            claimed.append(window.span)
            changes.append(CorrectionChange(original: original, corrected: replacement))
        }

        return Self.applying(replacements, to: text)
    }

    // MARK: - Pass 2/3: vocabulary matching + casing

    private struct VocabCandidate {
        let entry: VocabularyEntry
        let normalized: String
        let phoneticKey: String
        let displayTerm: String
    }

    private func applyVocabulary(
        to text: String,
        vocabulary: [VocabularyEntry],
        changes: inout [CorrectionChange]
    ) -> String {
        var byNormalized: [String: VocabCandidate] = [:]
        var fuzzyCandidates: [VocabCandidate] = []
        var vocabTermsLowercased: Set<String> = []

        for entry in vocabulary {
            let term = entry.term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let display = entry.category == .acronym ? term.uppercased() : term
            let normalized = Self.normalize(term)
            guard !normalized.isEmpty else { continue }
            let candidate = VocabCandidate(
                entry: entry,
                normalized: normalized,
                phoneticKey: Self.phoneticKey(normalized),
                displayTerm: display
            )
            if byNormalized[normalized] == nil {
                byNormalized[normalized] = candidate
            }
            if normalized.count >= Self.minFuzzyLength {
                fuzzyCandidates.append(candidate)
            }
            vocabTermsLowercased.insert(term.lowercased())
        }
        guard !byNormalized.isEmpty else { return text }

        let tokens = Self.wordTokens(in: text)
        var replacements: [Replacement] = []
        var claimed: [Range<Int>] = []

        for window in Self.windows(over: tokens, in: text) {
            guard !Self.overlapsAny(window.span, claimed) else { continue }

            let original = String(text[window.range])
            let candidateNorm = Self.normalize(original)
            guard candidateNorm.count >= 2 else { continue }
            let isSingleWord = window.words.count == 1

            var matched: VocabCandidate?

            if let exact = byNormalized[candidateNorm] {
                // Exact after normalization (case/spacing/punctuation only).
                // Guard single common words; multi-word joins are safe.
                if !(isSingleWord && CommonWords.contains(candidateNorm)) {
                    matched = exact
                }
            } else if candidateNorm.count >= Self.minFuzzyLength,
                      !vocabTermsLowercased.contains(original.lowercased()),
                      !(isSingleWord && CommonWords.contains(candidateNorm)) {
                // Fuzzy: phonetic key, length, and edit distance must all be close.
                var best: (candidate: VocabCandidate, distance: Int)?
                for candidate in fuzzyCandidates where Self.isFuzzyMatch(candidateNorm, candidate.normalized) {
                    let distance = Self.damerauLevenshtein(candidateNorm, candidate.normalized)
                    if distance < (best?.distance ?? .max) {
                        best = (candidate, distance)
                    }
                }
                matched = best?.candidate
            }

            guard let matched, matched.displayTerm != original else {
                // Identical text still claims the span so sub-windows of a
                // correct multi-word term aren't re-matched piecemeal.
                if let m = matched, m.displayTerm == original {
                    claimed.append(window.span)
                }
                continue
            }

            // Preserve sentence-initial capitalization for terms with no
            // intentional casing of their own (e.g. "prescribers"), matching
            // the rule pass. Terms with deliberate casing (MarkLogic, SPARQL,
            // names) are left exactly as stored.
            var replacement = matched.displayTerm
            if replacement == replacement.lowercased(),
               let first = original.first, first.isUppercase {
                replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
            }

            // Sentence-initial re-capitalization can round-trip back to the
            // original (e.g. "Prescribers" → "prescribers" → "Prescribers");
            // that's a no-op, so claim the span but record nothing.
            guard replacement != original else {
                claimed.append(window.span)
                continue
            }

            replacements.append(Replacement(range: window.range, span: window.span, text: replacement))
            claimed.append(window.span)
            changes.append(CorrectionChange(original: original, corrected: replacement))
        }

        return Self.applying(replacements, to: text)
    }

    // MARK: - Tokenization & windows

    private struct WordToken {
        let word: String
        let range: Range<String.Index>
        let span: Range<Int>  // UTF-16 offsets, for cheap overlap checks
    }

    private struct Window {
        let words: [String]
        let range: Range<String.Index>
        let span: Range<Int>
    }

    private struct Replacement {
        let range: Range<String.Index>
        let span: Range<Int>
        let text: String
    }

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9']+")

    private static func wordTokens(in text: String) -> [WordToken] {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return WordToken(
                word: String(text[range]),
                range: range,
                span: match.range.location..<(match.range.location + match.range.length)
            )
        }
    }

    /// All n-gram windows, widest first, whose words are separated by
    /// whitespace only (never across punctuation).
    private static func windows(over tokens: [WordToken], in text: String) -> [Window] {
        var result: [Window] = []
        for n in stride(from: maxWindow, through: 1, by: -1) {
            guard tokens.count >= n else { continue }
            for start in 0...(tokens.count - n) {
                let slice = tokens[start..<(start + n)]
                if n > 1 {
                    var contiguous = true
                    for (a, b) in zip(slice, slice.dropFirst()) {
                        let between = text[a.range.upperBound..<b.range.lowerBound]
                        if !between.allSatisfy(\.isWhitespace) { contiguous = false; break }
                    }
                    guard contiguous else { continue }
                }
                guard let first = slice.first, let last = slice.last else { continue }
                result.append(Window(
                    words: slice.map(\.word),
                    range: first.range.lowerBound..<last.range.upperBound,
                    span: first.span.lowerBound..<last.span.upperBound
                ))
            }
        }
        return result
    }

    private static func overlapsAny(_ span: Range<Int>, _ claimed: [Range<Int>]) -> Bool {
        claimed.contains { $0.overlaps(span) }
    }

    /// Applies replacements back-to-front so earlier ranges stay valid.
    private static func applying(_ replacements: [Replacement], to text: String) -> String {
        var result = text
        for replacement in replacements.sorted(by: { $0.span.lowerBound > $1.span.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    // MARK: - String metrics

    /// Lowercased alphanumerics only — spacing, hyphens, apostrophes, case
    /// all collapse ("Mark Logic" and "MarkLogic" both → "marklogic").
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Compact phonetic key over a normalized (lowercase alnum) string:
    /// maps confusable consonants together, drops vowels after the first
    /// character, collapses runs. "sparql" and "sparkle" both → "sprkl".
    static func phoneticKey(_ normalized: String) -> String {
        let mapped = normalized.replacingOccurrences(of: "ph", with: "f")
        let consonantMap: [Character: Character] = ["q": "k", "c": "k", "z": "s", "x": "k"]
        var out: [Character] = []
        for (i, ch) in mapped.enumerated() {
            let c = consonantMap[ch] ?? ch
            if i == 0 {
                out.append(c)
            } else if !"aeiouhwy".contains(c) {
                if out.last != c { out.append(c) }
            }
        }
        return String(out)
    }

    /// Whether two normalized (lowercase alnum) strings are close enough to
    /// treat as the same fuzzy-matched term: same phonetic key, similar
    /// length, and low edit-distance ratio. Shared by the corrector, the
    /// vocabulary ranker, and LLM context filtering so all three apply the
    /// same false-positive guards.
    static func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        guard a.count >= minFuzzyLength, b.count >= minFuzzyLength else { return false }
        guard abs(a.count - b.count) <= maxFuzzyLengthDiff else { return false }
        guard phoneticKey(a) == phoneticKey(b) else { return false }
        let distance = damerauLevenshtein(a, b)
        let ratio = Double(distance) / Double(max(a.count, b.count))
        return ratio <= maxFuzzyRatio
    }

    /// Damerau-Levenshtein (optimal string alignment) distance.
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var previous2 = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    current[j] = Swift.min(current[j], previous2[j - 2] + 1)  // transposition
                }
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[t.count]
    }
}
