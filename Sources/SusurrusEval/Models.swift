import Foundation
import SusurrusKit

// MARK: - Corpus

struct ScriptEntry: Codable {
    var id: String
    var text: String
    var tags: [String]
    var silenceSeconds: Double?

    var isSilence: Bool { silenceSeconds != nil || tags.contains("silence") }
}

/// The manifest line model lives in SusurrusKit so the app can write
/// captured clips (tier C) in the same format.
typealias ManifestEntry = EvalManifestEntry

/// `vocabulary.json`: the vocabulary, rules and recent-context terms a run
/// is scored and prompted with. Written by `snapshot` or by hand.
struct VocabularyFile: Codable {
    var snapshotDate: Date
    var entries: [VocabularyEntry]
    var rules: [CorrectionRule]
    var contextTerms: [String]

    init(snapshotDate: Date, entries: [VocabularyEntry], rules: [CorrectionRule], contextTerms: [String]) {
        self.snapshotDate = snapshotDate
        self.entries = entries
        self.rules = rules
        self.contextTerms = contextTerms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotDate = try c.decodeIfPresent(Date.self, forKey: .snapshotDate) ?? Date()
        entries = try c.decodeIfPresent([VocabularyEntry].self, forKey: .entries) ?? []
        rules = try c.decodeIfPresent([CorrectionRule].self, forKey: .rules) ?? []
        contextTerms = try c.decodeIfPresent([String].self, forKey: .contextTerms) ?? []
    }

    /// Scoring tracks every entry's display term (acronyms uppercased, as
    /// the ranker does).
    var trackedTerms: [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let term = entry.category == .acronym ? entry.term.uppercased() : entry.term
            return seen.insert(term).inserted ? term : nil
        }
    }
}

// MARK: - Config

enum PromptMode: String, Codable, Sendable {
    case ranker
    case noPrompt = "none"
}

enum PreviewMode: String, Codable, Sendable {
    case decode
    case noPreview = "none"
}

struct EvalConfig: Codable, Sendable {
    var name: String
    var model: String
    var decode: FinalDecodeConfig
    var prompt: PromptMode
    var preview: PreviewMode
    var corrector: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "unnamed"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "small"
        decode = try c.decodeIfPresent(FinalDecodeConfig.self, forKey: .decode) ?? .production
        prompt = try c.decodeIfPresent(PromptMode.self, forKey: .prompt) ?? .ranker
        preview = try c.decodeIfPresent(PreviewMode.self, forKey: .preview) ?? .decode
        corrector = try c.decodeIfPresent(Bool.self, forKey: .corrector) ?? true
    }
}

// MARK: - Run output

struct ClipResult: Codable {
    var id: String
    var tags: [String]
    /// nil in runs written before tier C existed (all verified).
    var verified: Bool?
    var seconds: Double
    var audioSHA256: String
    var reference: String
    var previewText: String
    var previewMs: Int
    var promptTerms: [String]
    var promptTokenCount: Int
    var outcome: String
    var decodeMs: Int
    var failure: String?
    var raw: String
    var final: String
    var scoreRaw: TranscriptScore
    var scoreFinal: TranscriptScore
    var segments: [FinalSegment]
}

/// A summed `TranscriptScore` (rates come from summed counts) plus timing.
/// `wer` and `formattedErrorRate` are stored for readers of the JSON; the
/// harness itself always recomputes from `score`.
struct Aggregate: Codable {
    var clips: Int
    var score: TranscriptScore
    var wer: Double
    var formattedErrorRate: Double
    /// Audio of clips whose decode actually ran (not skipped as silent or
    /// too short), so RTF isn't flattered by free skips.
    var audioSeconds: Double
    var decodeSeconds: Double
    var rtf: Double
}

struct StageAggregates: Codable {
    var raw: Aggregate
    var final: Aggregate
}

struct RunSummary: Codable {
    var overall: StageAggregates
    var byTag: [String: StageAggregates]
}

struct RunFile: Codable {
    var name: String
    var createdAt: Date
    var gitCommit: String?
    var osVersion: String
    var modelFolder: String
    var config: EvalConfig
    var corpus: String
    /// Verified clips only: the headline numbers and what `compare` reads.
    var clips: [ClipResult]
    var summary: RunSummary
    /// Unverified clips (tier C before `review`) the run skipped.
    var unverifiedSkipped: Int?
    /// Unverified clips scored with `--include-unverified`, kept apart so
    /// they never reach `summary` or the gate.
    var unverifiedClips: [ClipResult]?
    var unverifiedSummary: RunSummary?
}

enum Aggregation {
    enum Stage { case raw, final }

    static func aggregate(_ clips: [ClipResult], stage: Stage) -> Aggregate {
        var total = TranscriptScore.zero
        var audio = 0.0, decode = 0.0
        for clip in clips {
            total = total + (stage == .raw ? clip.scoreRaw : clip.scoreFinal)
            if clip.outcome != "silent" && clip.outcome != "tooShort" {
                audio += clip.seconds
                decode += Double(clip.decodeMs) / 1000
            }
        }
        return Aggregate(
            clips: clips.count, score: total, wer: total.wer, formattedErrorRate: total.formattedErrorRate,
            audioSeconds: audio, decodeSeconds: decode, rtf: audio > 0 ? decode / audio : 0
        )
    }

    static func stages(_ clips: [ClipResult]) -> StageAggregates {
        StageAggregates(raw: aggregate(clips, stage: .raw), final: aggregate(clips, stage: .final))
    }

    static func summary(_ clips: [ClipResult]) -> RunSummary {
        var byTag: [String: StageAggregates] = [:]
        for tag in Set(clips.flatMap(\.tags)) {
            byTag[tag] = stages(clips.filter { $0.tags.contains(tag) })
        }
        return RunSummary(overall: stages(clips), byTag: byTag)
    }
}
