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
    /// How many times the user has *made* this edit. Not how often the rule
    /// has fixed anything — see `fireCount` for that.
    public var hitCount: Int
    /// Disabled rules are kept for bookkeeping but never applied.
    public var enabled: Bool
    public let createdAt: Date
    public let source: Source
    /// How many final transcripts this rule has actually corrected. The only
    /// evidence that a rule earns its false-positive risk.
    public var fireCount: Int
    public var lastFiredAt: Date?

    public init(
        id: UUID = UUID(),
        match: String,
        replacement: String,
        hitCount: Int = 1,
        enabled: Bool = true,
        createdAt: Date = Date(),
        source: Source = .learned,
        fireCount: Int = 0,
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.match = Self.normalizeMatch(match)
        self.replacement = replacement
        self.hitCount = hitCount
        self.enabled = enabled
        self.createdAt = createdAt
        self.source = source
        self.fireCount = fireCount
        self.lastFiredAt = lastFiredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, match, replacement, hitCount, enabled, createdAt, source, fireCount, lastFiredAt
    }

    /// Hand-written so rules persisted before telemetry existed still decode.
    /// `rules()` is `(try? decode) ?? []`, so any throw here would silently
    /// erase every rule the user has ever taught.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Assigned directly rather than through normalizeMatch: stored matches
        // were normalized at write time, and this keeps encode/decode a
        // faithful round trip.
        match = try c.decode(String.self, forKey: .match)
        replacement = try c.decode(String.self, forKey: .replacement)
        hitCount = try c.decode(Int.self, forKey: .hitCount)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decode(Source.self, forKey: .source)
        fireCount = try c.decodeIfPresent(Int.self, forKey: .fireCount) ?? 0
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
    }

    /// Canonical form for matching: lowercased, single-spaced.
    public static func normalizeMatch(_ text: String) -> String {
        text.lowercased()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
