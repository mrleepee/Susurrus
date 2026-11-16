import Foundation

/// Spelling fixes that need no vocabulary: the same thing written one way.
/// Runs before the corrector, on every final transcript.
public enum TextNormalizer {

    public static func normalize(_ text: String) -> String {
        countryAbbreviations(text)
    }

    /// "U.K.", "U. K.", "U K." → "UK"; likewise "US". One dictation on 11-16
    /// had "UK", "U.K." and "U K." The abbreviation's last dot is kept only
    /// where it also ends the sentence (end of text, or a capital follows),
    /// so a mid-sentence "U K." no longer starts a false sentence.
    static func countryAbbreviations(_ text: String) -> String {
        let ns = text as NSString
        let matches = abbreviationRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let letter = ns.substring(with: match.range(at: 1))
            var replacement = "U" + letter
            if ns.substring(with: match.range).hasSuffix("."), endsSentence(after: range.upperBound, in: result) {
                replacement += "."
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // "U", then a dot and/or spaces, then K or S, then an optional dot — with
    // at least one dot or space between the letters ("UK" itself is left
    // alone) and no letter on either side ("US Open" fine, "USB" untouched).
    private static let abbreviationRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.])U(?:\\.\\s?|\\s)([KS])(?:\\.(?![\\p{L}])|(?![\\p{L}\\p{N}.]))"
    )

    private static func endsSentence(after index: String.Index, in text: String) -> Bool {
        guard let next = text[index...].first(where: { !$0.isWhitespace }) else { return true }
        return next.isUppercase
    }
}
