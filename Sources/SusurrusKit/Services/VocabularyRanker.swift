import Foundation

/// Ranks vocabulary terms for the final-decode prompt-token budget.
///
/// The budget (~48 tokens ≈ 10 terms) is far smaller than a working
/// vocabulary, so which terms make the cut decides whether biasing helps.
/// Ranking, most relevant first:
///
/// 1. Terms evidenced in the streaming preview text — exact-normalized or
///    phonetic hits. A phonetic-but-not-exact hit means the preview likely
///    *misrecognized* the term, exactly when biasing the final decode
///    matters most.
/// 2. Bias terms drawn from recent dictation history.
/// 3. Newly learned terms, briefly (see below).
/// 4. Remaining vocabulary by category priority (names and products first).
///
/// Tier 3 exists because tier 4 sorts by `useCount`, which is rich-get-richer:
/// a term you just taught starts at zero and loses every slot to terms Whisper
/// already handles. Measured on 200 dictations, "Posthog" reached the prompt
/// 0 times in the days after it was learned while "MarkLogic" (24 uses, 0
/// repairs) took a slot on 193 of 260 stops. A term is most likely to be
/// spoken again right after you say it, so a fresh term gets a bounded head
/// start rather than having to earn its way up from the bottom.
///
/// The tier is deliberately narrow: `graceWindow` from being added, only while
/// `useCount` is under `graceUseThreshold`, and never more than
/// `maxGraceTerms` slots. It cannot starve the evergreen tier, and every term
/// leaves it on its own — by being used, or by aging out.
public struct VocabularyRanker: Sendable {

    private static let categoryPriority: [VocabularyCategory] = [
        .product, .person, .company, .technical, .acronym, .project, .place, .custom
    ]

    /// How long a term counts as newly learned.
    static let graceWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Once a term has been used this many times it can hold its own in tier 4.
    static let graceUseThreshold = 3
    /// Hard cap so a bulk import (or first-launch seeding) can't fill the budget.
    static let maxGraceTerms = 5
    /// Hard cap on tier 2, for the same reason `maxGraceTerms` exists: no tier
    /// may take the whole budget.
    ///
    /// Tier 2 is fed by `recentBiasTerms`, which returns up to 20 terms into a
    /// budget of roughly 15. Whenever recent dictations happen to be dense in
    /// capitalised words, tier 2 alone filled the prompt and the user's own
    /// curated vocabulary — the terms they explicitly taught — never got a slot.
    /// Measured 2026-08-18: curated vocabulary fell from 66% of prompt slots to
    /// 33% as the user's subject matter shifted, with names they had corrected
    /// before (`Jayendra`, `Balvinder`, `Divya`) crowded out and re-mangled.
    /// Capping tier 2 at 8 restores it to 73% on the same data.
    ///
    /// Roughly half the budget. Recent context is a guess about what you might
    /// say; vocabulary is a statement of what you have said you say.
    static let maxContextTerms = 8

    public init() {}

    public func selectTerms(
        previewText: String,
        vocabulary: [VocabularyEntry],
        contextTerms: [String] = [],
        now: Date = Date()
    ) -> [String] {
        var selected: [String] = []
        var seen: Set<String> = []

        func add(_ term: String) {
            let key = term.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            selected.append(term)
        }

        // Preview n-grams (1–3 words), normalized, with phonetic keys.
        let previewWords = previewText
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        var previewNorms: Set<String> = []
        var previewKeys: [(norm: String, key: String)] = []
        for n in 1...3 {
            guard previewWords.count >= n else { break }
            for start in 0...(previewWords.count - n) {
                let norm = TranscriptCorrector.normalize(previewWords[start..<(start + n)].joined())
                guard norm.count >= 2, previewNorms.insert(norm).inserted else { continue }
                previewKeys.append((norm, TranscriptCorrector.phoneticKey(norm)))
            }
        }

        // Tier 1: terms evidenced in the preview, best match first. Exact
        // hits all score 0, so an explicit tiebreak (usage desc, then term
        // alphabetic) keeps budget-packing reproducible across runs with
        // identical input — Swift's sort is not stable.
        var evidenced: [(term: String, score: Double, useCount: Int)] = []
        for entry in vocabulary {
            let display = entry.category == .acronym ? entry.term.uppercased() : entry.term
            let norm = TranscriptCorrector.normalize(entry.term)
            guard norm.count >= 2 else { continue }
            if previewNorms.contains(norm) {
                evidenced.append((display, 0, entry.useCount ?? 0))
                continue
            }
            guard norm.count >= TranscriptCorrector.minFuzzyLength else { continue }
            var best = Double.infinity
            for (candidateNorm, _) in previewKeys where TranscriptCorrector.isFuzzyMatch(candidateNorm, norm) {
                let distance = TranscriptCorrector.damerauLevenshtein(candidateNorm, norm)
                let ratio = Double(distance) / Double(max(candidateNorm.count, norm.count))
                best = Swift.min(best, ratio)
            }
            if best.isFinite {
                evidenced.append((display, best, entry.useCount ?? 0))
            }
        }
        let rankedEvidence = evidenced.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.term < b.term
        }
        for hit in rankedEvidence {
            add(hit.term)
        }

        // Tier 2: recent history terms, best-evidenced first (they arrive
        // ranked by how many recent dictations contain them). Capped — see
        // maxContextTerms.
        for term in contextTerms.prefix(Self.maxContextTerms) {
            add(term)
        }

        // Tier 3: newly learned terms, newest first. Ties break on term so a
        // batch added in one pass packs reproducibly.
        let grace = vocabulary
            .filter { entry in
                guard let created = entry.createdAt else { return false }
                guard (entry.useCount ?? 0) < Self.graceUseThreshold else { return false }
                return now.timeIntervalSince(created) < Self.graceWindow
            }
            .sorted { a, b in
                let ca = a.createdAt ?? .distantPast
                let cb = b.createdAt ?? .distantPast
                return ca == cb ? a.term < b.term : ca > cb
            }
            .prefix(Self.maxGraceTerms)
        for entry in grace {
            add(entry.category == .acronym ? entry.term.uppercased() : entry.term)
        }

        // Tier 4: the rest of the vocabulary — most-used first, then by
        // category priority, stable within a category.
        let rank = Dictionary(
            uniqueKeysWithValues: Self.categoryPriority.enumerated().map { ($1, $0) }
        )
        let remaining = vocabulary
            .enumerated()
            .sorted { a, b in
                let ua = a.element.useCount ?? 0
                let ub = b.element.useCount ?? 0
                if ua != ub { return ua > ub }
                let ra = rank[a.element.category] ?? .max
                let rb = rank[b.element.category] ?? .max
                return ra == rb ? a.offset < b.offset : ra < rb
            }
        for (_, entry) in remaining {
            add(entry.category == .acronym ? entry.term.uppercased() : entry.term)
        }

        return selected
    }
}
