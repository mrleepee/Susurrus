import Foundation

/// A single "this capital looks wrong" suggestion, anchored to the exact
/// range it came from so applying it can't hit a same-spelled word elsewhere.
public struct CasingSuggestion: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let range: Range<String.Index>
    public let original: String
    public let suggested: String

    public init(id: UUID = UUID(), range: Range<String.Index>, original: String, suggested: String) {
        self.id = id
        self.range = range
        self.original = original
        self.suggested = suggested
    }
}

/// Per-user casing model, learned from the user's own approved transcripts.
///
/// Whisper Title-Cases noun phrases it reads as names — "My Voice Dictation to
/// Text Project", "a Global News Application". A fixed frequency list can't
/// catch these (measured: `CommonWords.top` covers 9 of 23 real cases, and it
/// is explicitly not the place for domain words), but the user's own prose can:
/// if "documents" appears lowercase mid-sentence 23 times and capitalized zero
/// times, a mid-phrase "Documents" is almost certainly Whisper's invention.
///
/// **These are suggestions, never automatic rewrites.** Measured over 200
/// dictations with leave-one-out evaluation, the best achievable precision is
/// ~73% at ~42% recall, and the precision/recall curve is *flat* across every
/// threshold — raising the evidence bar from 3 to 8 sightings drops recall from
/// 46% to 19% and buys no precision at all. That flatness says the remaining
/// errors are not a tuning problem: "K Bank", "Content Stats API" and a UI
/// button list ("we have Insert, Cancel, Add, Copy") are real names that happen
/// to be ordinary words, and no amount of corpus statistics separates them.
///
/// One wrong change in three is unacceptable for a silent edit and completely
/// fine for a suggestion you glance at and ignore, which is why this type only
/// ever proposes. Volume is low enough to stay quiet — roughly one flag per ten
/// dictations.
public struct CasingProfile: Sendable {

    /// lowercased word -> (times seen lowercase mid-phrase, times seen capitalized mid-phrase)
    private let counts: [String: (lower: Int, upper: Int)]

    /// Minimum lowercase sightings before the profile will say anything.
    public static let minLowercaseSightings = 3
    /// Share of mid-phrase sightings that must be lowercase.
    public static let minLowercaseRatio = 0.9

    public init(counts: [String: (lower: Int, upper: Int)] = [:]) {
        self.counts = counts
    }

    /// Build from approved transcripts — the text the user accepted, not raw
    /// ASR, so the model learns the casing they actually wanted.
    public static func build(from texts: [String]) -> CasingProfile {
        var counts: [String: (lower: Int, upper: Int)] = [:]
        for text in texts {
            let tokens = Self.tokenize(text)
            for (index, token) in tokens.enumerated() where token.isWord {
                guard Self.isMidPhrase(tokens, index) else { continue }
                let key = token.text.lowercased()
                var entry = counts[key] ?? (0, 0)
                if token.text.first?.isUppercase == true {
                    entry.upper += 1
                } else {
                    entry.lower += 1
                }
                counts[key] = entry
            }
        }
        return CasingProfile(counts: counts)
    }

    /// Mid-phrase capitals this profile believes should be lowercase.
    public func suggestions(for text: String, vocabulary: [VocabularyEntry]) -> [CasingSuggestion] {
        let vocabTerms = Set(vocabulary.map { $0.term.lowercased() })
        let tokens = Self.tokenize(text)
        var out: [CasingSuggestion] = []

        for (index, token) in tokens.enumerated() where token.isWord {
            let word = token.text
            guard let first = word.first, first.isUppercase else { continue }
            // "I" is always capitalized; ALL-CAPS is an acronym, not Title Case.
            guard word.lowercased() != "i", word != word.uppercased() else { continue }
            guard Self.isMidPhrase(tokens, index) else { continue }
            // Every measured true positive followed a plain word. Capitals after
            // punctuation are quoted speech ("I said to him, Can you…") or list
            // labels ("Ctrl, Option, Space") — dropping them lifted precision
            // from 38% to 60% and cost one true positive.
            guard index > 0, tokens[index - 1].isWord else { continue }
            // A run like "Insert, Cancel, Add" is a list of labels, not prose.
            if index + 2 < tokens.count,
               tokens[index + 1].text == ",",
               tokens[index + 2].text.first?.isUppercase == true {
                continue
            }
            // The user's own vocabulary always wins — it is the explicit
            // statement of what is a name.
            guard !vocabTerms.contains(word.lowercased()) else { continue }

            guard let entry = counts[word.lowercased()] else { continue }
            let total = entry.lower + entry.upper
            guard entry.lower >= Self.minLowercaseSightings,
                  total > 0,
                  Double(entry.lower) / Double(total) >= Self.minLowercaseRatio else { continue }

            let suggested = word.prefix(1).lowercased() + word.dropFirst()
            guard suggested != word else { continue }
            out.append(CasingSuggestion(range: token.range, original: word, suggested: suggested))
        }
        return out
    }

    /// Applies suggestions back-to-front so earlier ranges stay valid.
    public static func apply(_ suggestions: [CasingSuggestion], to text: String) -> String {
        var result = text
        for suggestion in suggestions.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard suggestion.range.upperBound <= result.endIndex,
                  String(result[suggestion.range]) == suggestion.original else { continue }
            result.replaceSubrange(suggestion.range, with: suggestion.suggested)
        }
        return result
    }

    // MARK: - Tokenizing

    struct Token {
        let text: String
        let range: Range<String.Index>
        let isWord: Bool
    }

    private static let pattern = try! NSRegularExpression(pattern: "[\\p{L}][\\p{L}']*|[.,;:!?]")

    static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        return Self.pattern
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let piece = String(text[range])
                return Token(text: piece, range: range, isWord: piece.first?.isLetter == true)
            }
    }

    /// A word is mid-phrase when it is neither the first token nor the first
    /// word of a sentence — those capitals are correct by definition.
    private static func isMidPhrase(_ tokens: [Token], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = tokens[index - 1].text
        return previous != "." && previous != "?" && previous != "!"
    }
}
