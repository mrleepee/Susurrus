import Foundation

/// Manages correction pairs from user edits, persisted to UserDefaults.
/// Provides relevance-ranked few-shot examples for the LLM cleanup prompt.
/// Auto-extracts proper noun corrections and adds them to vocabulary.
public final class CorrectionLearningManager: CorrectionLearning, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let storageKey = "correctionPairs"
    public static let maxPairs = 50

    private let vocabularyManager: VocabularyManaging?

    public init(vocabularyManager: VocabularyManaging? = nil, defaults: UserDefaults = .standard) {
        self.vocabularyManager = vocabularyManager
        self.defaults = defaults
    }

    /// Factory for testing with isolated UserDefaults.
    public static func createForTesting() -> CorrectionLearningManager {
        CorrectionLearningManager(
            defaults: UserDefaults(suiteName: "com.susurrus.correction.test.\(UUID().uuidString)")!
        )
    }

    // MARK: - CorrectionLearning

    public func recordCorrection(raw: String, edited: String) {
        guard raw != edited else { return }

        var pairs = loadAll()
        pairs.insert(CorrectionPair(rawText: raw, editedText: edited), at: 0)

        // Cap at max
        if pairs.count > Self.maxPairs {
            pairs = Array(pairs.prefix(Self.maxPairs))
        }

        save(pairs)

        // Auto-extract proper noun corrections into vocabulary
        if let vocab = vocabularyManager {
            extractProperNouns(raw: raw, edited: edited, into: vocab)
        }
    }

    public func relevantCorrections(for text: String, limit: Int) -> [CorrectionPair] {
        let all = loadAll()
        guard !all.isEmpty else { return [] }

        let queryWords = Set(text.lowercased().split(separator: " ").map(String.init))

        let scored = all.map { pair -> (pair: CorrectionPair, score: Double) in
            let pairWords = Set(pair.rawText.lowercased().split(separator: " ").map(String.init))
            let intersection = queryWords.intersection(pairWords).count
            let union = queryWords.union(pairWords).count
            let jaccard = union > 0 ? Double(intersection) / Double(union) : 0
            return (pair, jaccard)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.pair)
    }

    public func allCorrections() -> [CorrectionPair] {
        loadAll()
    }

    public func clearCorrections() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    public func fewShotString(for text: String, limit: Int) -> String {
        let pairs = relevantCorrections(for: text, limit: limit)
        guard !pairs.isEmpty else { return "" }

        return pairs.map { pair in
            "Raw: \"\(pair.rawText)\" → Fixed: \"\(pair.editedText)\""
        }.joined(separator: "\n")
    }

    // MARK: - Proper noun extraction

    /// Extract case-only and capitalization corrections and add to vocabulary.
    private func extractProperNouns(raw: String, edited: String, into vocab: VocabularyManaging) {
        let rawWords = raw.split(separator: " ").map(String.init)
        let editedWords = edited.split(separator: " ").map(String.init)

        let existingTerms = Set(vocab.entries().map({ $0.term.lowercased() }))

        for (rawWord, editedWord) in zip(rawWords, editedWords) {
            // Case-only change (e.g., "databid" → "DataBid")
            if rawWord.lowercased() == editedWord.lowercased() && rawWord != editedWord {
                let lowered = editedWord.lowercased()
                guard !existingTerms.contains(lowered) else { continue }
                vocab.addEntry(VocabularyEntry(term: editedWord, category: .custom))
            }
        }
    }

    // MARK: - Persistence

    private func loadAll() -> [CorrectionPair] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([CorrectionPair].self, from: data)) ?? []
    }

    private func save(_ pairs: [CorrectionPair]) {
        guard let data = try? JSONEncoder().encode(pairs) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
