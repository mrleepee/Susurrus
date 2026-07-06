import Foundation

/// Guards against LLM post-processing rewriting the user's words.
/// The LLM's job is punctuation, casing, and error fixes — if its output
/// drifts too far from the input, the deterministic text is kept instead.
public enum TranscriptGuardrail {

    /// Minimum word-level similarity (0…1) between LLM input and output.
    static let minSimilarity = 0.5

    /// Accepted output length relative to input, in words.
    static let lengthRatioBounds = 0.5...1.6

    /// Whether the LLM output is a faithful cleanup of the input.
    public static func accepts(input: String, output: String) -> Bool {
        let inputWords = normalizedWords(input)
        let outputWords = normalizedWords(output)
        guard !inputWords.isEmpty, !outputWords.isEmpty else { return false }

        let ratio = Double(outputWords.count) / Double(inputWords.count)
        guard lengthRatioBounds.contains(ratio) else { return false }

        let lcs = lcsLength(inputWords, outputWords)
        let similarity = 2.0 * Double(lcs) / Double(inputWords.count + outputWords.count)
        return similarity >= minSimilarity
    }

    /// Lowercased alphanumeric words — punctuation and casing changes are
    /// exactly what the LLM is *supposed* to do, so they don't count as drift.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Longest common subsequence length over word arrays.
    static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : Swift.max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
