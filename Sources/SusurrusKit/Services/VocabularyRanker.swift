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
/// 2. Bias terms drawn from the active notebook's recent entries.
/// 3. Remaining vocabulary by category priority (names and products first).
public struct VocabularyRanker: Sendable {

    private static let categoryPriority: [VocabularyCategory] = [
        .product, .person, .company, .technical, .acronym, .project, .place, .custom
    ]

    public init() {}

    public func selectTerms(
        previewText: String,
        vocabulary: [VocabularyEntry],
        notebookTerms: [String] = []
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
            guard norm.count >= 4 else { continue }
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

        // Tier 2: recent notebook terms.
        for term in notebookTerms {
            add(term)
        }

        // Tier 3: the rest of the vocabulary — most-used first, then by
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
