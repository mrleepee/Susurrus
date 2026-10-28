import Foundation

/// Accuracy metrics for one transcript against a reference. Codable so the
/// eval harness can write runs to disk and compare them later.
public struct TranscriptScore: Codable, Equatable, Sendable {
    /// Normalized reference length — the WER denominator.
    public var referenceWords: Int
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int

    /// Case- and punctuation-sensitive tokens in the reference, and the edit
    /// distance over them. Catches the casing and full-stop errors that
    /// normalized WER deliberately ignores.
    public var formattedTokens: Int
    public var formattedErrors: Int

    /// Occurrences of tracked terms (vocabulary) in the reference, and how
    /// many of those the hypothesis reproduced exactly, case-sensitively.
    public var termsExpected: Int
    public var termsHit: Int
    /// Term occurrences in the hypothesis beyond what the reference contains:
    /// a corrector or prompt putting a vocabulary word where none was said.
    public var termFalseFires: Int
    /// Reference terms the hypothesis missed, one entry per missed occurrence.
    public var missedTerms: [String]

    /// Runs of `TranscriptScorer.runLength`+ consecutive deleted words (lost
    /// speech) and inserted words (hallucination).
    public var droppedRuns: Int
    public var insertedRuns: Int

    /// Sentence terminators in the hypothesis where the reference has none —
    /// the "pause becomes a full stop" error.
    public var extraSentenceBreaks: Int

    public var errors: Int { substitutions + deletions + insertions }

    public var wer: Double {
        referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords)
    }

    public var formattedErrorRate: Double {
        formattedTokens == 0 ? (formattedErrors == 0 ? 0 : 1) : Double(formattedErrors) / Double(formattedTokens)
    }

    public static let zero = TranscriptScore(
        referenceWords: 0, substitutions: 0, deletions: 0, insertions: 0,
        formattedTokens: 0, formattedErrors: 0,
        termsExpected: 0, termsHit: 0, termFalseFires: 0, missedTerms: [],
        droppedRuns: 0, insertedRuns: 0, extraSentenceBreaks: 0
    )

    /// Sum of two scores — aggregate rates are computed from summed counts,
    /// never by averaging per-clip rates (which over-weights short clips).
    public static func + (a: TranscriptScore, b: TranscriptScore) -> TranscriptScore {
        TranscriptScore(
            referenceWords: a.referenceWords + b.referenceWords,
            substitutions: a.substitutions + b.substitutions,
            deletions: a.deletions + b.deletions,
            insertions: a.insertions + b.insertions,
            formattedTokens: a.formattedTokens + b.formattedTokens,
            formattedErrors: a.formattedErrors + b.formattedErrors,
            termsExpected: a.termsExpected + b.termsExpected,
            termsHit: a.termsHit + b.termsHit,
            termFalseFires: a.termFalseFires + b.termFalseFires,
            missedTerms: a.missedTerms + b.missedTerms,
            droppedRuns: a.droppedRuns + b.droppedRuns,
            insertedRuns: a.insertedRuns + b.insertedRuns,
            extraSentenceBreaks: a.extraSentenceBreaks + b.extraSentenceBreaks
        )
    }
}

/// Scores a hypothesis transcript against a reference. Pure — no model, no
/// I/O — so the metrics themselves are unit-tested, and the eval harness
/// and any future quality gate cannot disagree about what a number means.
public enum TranscriptScorer {

    /// Minimum consecutive deleted/inserted words counted as a dropped or
    /// hallucinated run. Single-word slips are ordinary substitution noise;
    /// three in a row is a phrase that was lost or invented.
    public static let runLength = 3

    public enum EditOp: Equatable, Sendable {
        case match, substitute, delete, insert
    }

    public static func score(reference: String, hypothesis: String, terms: [String] = []) -> TranscriptScore {
        let refWords = normalizedWords(reference)
        let hypWords = normalizedWords(hypothesis)
        let ops = align(refWords, hypWords)

        let refFormatted = formattedTokens(reference)
        let hypFormatted = formattedTokens(hypothesis)
        let formattedOps = align(refFormatted, hypFormatted)

        var termsExpected = 0, termsHit = 0, falseFires = 0
        var missed: [String] = []
        for term in Set(terms) {
            let inRef = occurrences(of: term, in: reference)
            let inHyp = occurrences(of: term, in: hypothesis)
            termsExpected += inRef
            termsHit += min(inRef, inHyp)
            falseFires += max(0, inHyp - inRef)
            missed += Array(repeating: term, count: max(0, inRef - inHyp))
        }

        return TranscriptScore(
            referenceWords: refWords.count,
            substitutions: ops.filter { $0 == .substitute }.count,
            deletions: ops.filter { $0 == .delete }.count,
            insertions: ops.filter { $0 == .insert }.count,
            formattedTokens: refFormatted.count,
            formattedErrors: formattedOps.filter { $0 != .match }.count,
            termsExpected: termsExpected,
            termsHit: termsHit,
            termFalseFires: falseFires,
            missedTerms: missed.sorted(),
            droppedRuns: runs(of: .delete, in: ops),
            insertedRuns: runs(of: .insert, in: ops),
            extraSentenceBreaks: extraBreaks(ops: formattedOps, ref: refFormatted, hyp: hypFormatted)
        )
    }

    // MARK: - Normalization

    /// Spelling variants that are not errors. Kept to a short explicit list:
    /// a generic -ise/-ize rule would also rewrite "rise" and "wise".
    private static let spellingVariants: [String: String] = [
        "realised": "realized", "realise": "realize", "organisation": "organization",
        "organise": "organize", "optimise": "optimize", "optimised": "optimized",
        "analyse": "analyze", "analysed": "analyzed", "prioritise": "prioritize",
        "colour": "color", "behaviour": "behavior", "favour": "favor",
        "centre": "center", "licence": "license", "catalogue": "catalog",
        "ok": "okay",
    ]

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
        "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    /// Lowercased words with punctuation, hyphens and number formatting
    /// folded away: "Thirty-percent, OK?" and "30 percent okay" compare equal.
    /// Digit grouping is dropped ("10,000" → "10000").
    public static func normalizedWords(_ text: String) -> [String] {
        var s = text.lowercased().replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "(\\d),(\\d{3})", with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "%", with: " percent")
        s = s.replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
        return s.split(separator: " ").compactMap { raw in
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard !word.isEmpty else { return nil }
            return numberWords[word] ?? spellingVariants[word] ?? word
        }
    }

    /// Case-preserving words plus punctuation marks as their own tokens.
    /// Hyphens and colons stay inside words ("dev-full", "xdmp:apply").
    public static func formattedTokens(_ text: String) -> [String] {
        let s = text.replacingOccurrences(of: "’", with: "'")
        let pattern = "[\\p{L}\\p{N}'][\\p{L}\\p{N}'\\-:/.]*[\\p{L}\\p{N}]|[\\p{L}\\p{N}]|[.,!?;]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return regex.matches(in: s, range: range).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    // MARK: - Alignment

    /// Levenshtein alignment, reference → hypothesis. On ties, prefers a
    /// match/substitution over a gap, so runs of deletions and insertions are
    /// only reported where they are unavoidable.
    public static func align(_ ref: [String], _ hyp: [String]) -> [EditOp] {
        let n = ref.count, m = hyp.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var ops: [EditOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                ops.append(ref[i - 1] == hyp[j - 1] ? .match : .substitute)
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.delete)
                i -= 1
            } else {
                ops.append(.insert)
                j -= 1
            }
        }
        return ops.reversed()
    }

    // MARK: - Derived metrics

    private static func runs(of kind: EditOp, in ops: [EditOp]) -> Int {
        var count = 0, current = 0
        for op in ops {
            current = op == kind ? current + 1 : 0
            if current == runLength { count += 1 }
        }
        return count
    }

    private static func isTerminator(_ token: String) -> Bool {
        token == "." || token == "?" || token == "!"
    }

    /// Walks the formatted alignment: a hypothesis terminator that was
    /// inserted, or that replaced a non-terminator (usually a comma), is an
    /// extra sentence break.
    private static func extraBreaks(ops: [EditOp], ref: [String], hyp: [String]) -> Int {
        var i = 0, j = 0, count = 0
        for op in ops {
            switch op {
            case .match:
                i += 1; j += 1
            case .substitute:
                if isTerminator(hyp[j]), !isTerminator(ref[i]) { count += 1 }
                i += 1; j += 1
            case .delete:
                i += 1
            case .insert:
                if isTerminator(hyp[j]) { count += 1 }
                j += 1
            }
        }
        return count
    }

    /// Case-sensitive whole-word occurrences. "Word" boundaries treat
    /// letters, digits and apostrophes as word characters, so "CTS" is not
    /// found inside "CTSs" but is found in "CTS:Register".
    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = "(?<![\\p{L}\\p{N}'])\(escaped)(?![\\p{L}\\p{N}'])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
