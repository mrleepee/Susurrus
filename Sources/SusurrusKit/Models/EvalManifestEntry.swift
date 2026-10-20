import Foundation

/// One line of an eval corpus's `manifest.jsonl` (see docs/eval-harness.md).
///
/// The first nine fields are common to every tier. The optional fields are
/// written by real-voice tiers only: captured dictations (`source: captured`)
/// carry what the app knew at capture time, so `review` can show it and the
/// raw output can be compared with later runs.
public struct EvalManifestEntry: Codable, Equatable, Sendable {
    public var id: String
    public var script: String
    /// Relative to the corpus directory, e.g. `clips/<id>.wav`.
    public var audio: String
    public var reference: String
    public var tags: [String]
    /// `tts`/`synthetic` (tiers A, B), `captured` (C) or `read` (D).
    public var source: String
    public var voice: String
    public var variant: String
    /// Only verified clips count toward a run's headline numbers.
    public var verified: Bool

    /// Raw ASR output of the stop-time decode, before any correction.
    public var raw: String?
    /// The corrector's output, i.e. what the review panel opened with.
    public var corrected: String?
    /// The bias terms packed into the final decode's prompt.
    public var promptTerms: [String]?
    /// Model folder name, e.g. `openai_whisper-small`.
    public var model: String?
    public var seconds: Double?
    public var capturedAt: Date?

    public init(
        id: String, script: String, audio: String, reference: String, tags: [String],
        source: String, voice: String, variant: String, verified: Bool,
        raw: String? = nil, corrected: String? = nil, promptTerms: [String]? = nil,
        model: String? = nil, seconds: Double? = nil, capturedAt: Date? = nil
    ) {
        self.id = id
        self.script = script
        self.audio = audio
        self.reference = reference
        self.tags = tags
        self.source = source
        self.voice = voice
        self.variant = variant
        self.verified = verified
        self.raw = raw
        self.corrected = corrected
        self.promptTerms = promptTerms
        self.model = model
        self.seconds = seconds
        self.capturedAt = capturedAt
    }

    /// Tiers C and D tag by length the same way the golden scripts do.
    public static func lengthTag(seconds: Double) -> String {
        seconds > 30 ? "long" : "short"
    }
}
