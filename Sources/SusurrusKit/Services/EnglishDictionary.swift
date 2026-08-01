import Foundation

/// Word list from the system dictionary, used to tell "this is an English word
/// Whisper happened to capitalize" from "this is a name I don't know".
///
/// On its own this signal is **not** safe to filter on: macOS ships `web2`,
/// which contains given names, so 11 of 20 real names in production data
/// (`Rajesh`, `Julia`, `Elizabeth`, `Paul`…) are in here alongside `document`
/// and `pipeline`. It is only the first of three conditions — see
/// `CasingProfile.writesInLowercase(_:)` for the evidence that separates them.
///
/// A missing or unreadable dictionary yields an empty set, which makes every
/// lookup false and leaves bias-term extraction exactly as it was.
public struct EnglishDictionary: Sendable {

    private let words: Set<String>

    public init(words: Set<String>) {
        self.words = words
    }

    /// The system list, loaded once on first use.
    public static let shared = EnglishDictionary(
        words: load(from: "/usr/share/dict/words")
    )

    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Whether the list loaded at all. False on systems without the BSD word
    /// list, where callers should expect every `contains` to be false.
    public var isAvailable: Bool { !words.isEmpty }

    static func load(from path: String) -> Set<String> {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: Set<String> = []
        out.reserveCapacity(240_000)
        for line in contents.split(separator: "\n") {
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            if !word.isEmpty { out.insert(word) }
        }
        return out
    }
}
