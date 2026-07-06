import Foundation

/// A deterministic text replacement learned from user edits (or added manually).
/// Applied to every final transcript before any LLM processing.
public struct CorrectionRule: Identifiable, Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case learned
        case manual
    }

    public let id: UUID
    /// The misrecognized n-gram (1–3 words), lowercased and single-spaced.
    public var match: String
    /// The replacement text, with intended casing.
    public var replacement: String
    /// How many times this correction has been observed in user edits.
    public var hitCount: Int
    /// Disabled rules are kept for bookkeeping but never applied.
    public var enabled: Bool
    public let createdAt: Date
    public let source: Source

    public init(
        id: UUID = UUID(),
        match: String,
        replacement: String,
        hitCount: Int = 1,
        enabled: Bool = true,
        createdAt: Date = Date(),
        source: Source = .learned
    ) {
        self.id = id
        self.match = Self.normalizeMatch(match)
        self.replacement = replacement
        self.hitCount = hitCount
        self.enabled = enabled
        self.createdAt = createdAt
        self.source = source
    }

    /// Canonical form for matching: lowercased, single-spaced.
    public static func normalizeMatch(_ text: String) -> String {
        text.lowercased()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
