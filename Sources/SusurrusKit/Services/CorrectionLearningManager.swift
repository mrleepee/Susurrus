import Foundation

/// What a recorded edit changed about future behaviour: rules that will now
/// rewrite transcriptions, and terms newly added to the vocabulary. Used to
/// tell the user what Susurrus just learned.
public struct LearningOutcome: Sendable, Equatable {
    public var activatedRules: [CorrectionRule] = []
    public var promotedTerms: [String] = []

    public var isEmpty: Bool { activatedRules.isEmpty && promotedTerms.isEmpty }

    public init(activatedRules: [CorrectionRule] = [], promotedTerms: [String] = []) {
        self.activatedRules = activatedRules
        self.promotedTerms = promotedTerms
    }
}

/// Manages correction pairs from user edits, persisted to UserDefaults.
/// Provides relevance-ranked few-shot examples for the LLM cleanup prompt.
/// Auto-extracts proper noun corrections and adds them to vocabulary.
public final class CorrectionLearningManager: CorrectionLearning, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let storageKey = "correctionPairs"
    private static let rulesKey = "correctionRules"
    public static let maxPairs = 50
    public static let maxRules = 200

    private let vocabularyManager: VocabularyManaging?

    /// Serializes load-modify-write on the shared UserDefaults keys.
    /// Recursive so a compound op like `recordCorrection` can freely call
    /// `addRule`/`setRuleEnabled` on the same thread without deadlocking,
    /// while the whole sequence stays atomic against other threads (the
    /// background dictation-stop task vs. main-thread UI edits).
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Shared production instance backed by `UserDefaults.standard`, wired to
    /// the shared vocabulary manager. All app and view call sites must use
    /// this so rule/pair writes from dictation and UI edits share one lock.
    public static let shared = CorrectionLearningManager(vocabularyManager: VocabularyManager.shared)

    /// Invoked (outside the lock) after an edit teaches something that
    /// changes future behaviour — a rule activating or a vocabulary
    /// promotion. Set once at app startup to surface it to the user.
    public var onLearn: (@Sendable (LearningOutcome) -> Void)?

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

        var outcome = LearningOutcome()
        withLock {
            var pairs = loadAll()
            pairs.insert(CorrectionPair(rawText: raw, editedText: edited), at: 0)

            // Cap at max
            if pairs.count > Self.maxPairs {
                pairs = Array(pairs.prefix(Self.maxPairs))
            }

            save(pairs)

            // Learn from the edit: word-level substitutions become replacement
            // rules; proper-noun replacements are promoted to vocabulary; edits
            // that undo a rule's output disable that rule.
            disableReversedRules(raw: raw, edited: edited)
            outcome = learnFromEdit(raw: raw, edited: edited)
        }
        // Outside the lock: the callback is arbitrary app code (notifications).
        if !outcome.isEmpty { onLearn?(outcome) }
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
        withLock { defaults.removeObject(forKey: Self.storageKey) }
    }

    public func fewShotString(for text: String, limit: Int) -> String {
        let pairs = relevantCorrections(for: text, limit: limit)
        guard !pairs.isEmpty else { return "" }

        return pairs.map { pair in
            "Raw: \"\(pair.rawText)\" → Fixed: \"\(pair.editedText)\""
        }.joined(separator: "\n")
    }

    // MARK: - Correction rules

    /// All stored rules, enabled or not.
    public func rules() -> [CorrectionRule] {
        guard let data = defaults.data(forKey: Self.rulesKey) else { return [] }
        return (try? JSONDecoder().decode([CorrectionRule].self, from: data)) ?? []
    }

    /// Rules eligible for application by the transcript corrector.
    public func activeRules() -> [CorrectionRule] {
        rules().filter(\.enabled)
    }

    /// Add a rule, merging with an existing rule for the same match
    /// (same-replacement sightings bump hitCount; a different replacement
    /// supersedes the old one).
    public func addRule(_ rule: CorrectionRule) {
        withLock {
            var all = rules()
            if let i = all.firstIndex(where: { $0.match == rule.match }) {
                if all[i].replacement == rule.replacement {
                    all[i].hitCount += rule.hitCount
                    all[i].enabled = all[i].enabled || rule.enabled
                } else {
                    all[i] = rule
                }
            } else {
                all.insert(rule, at: 0)
                if all.count > Self.maxRules {
                    all = Array(all.prefix(Self.maxRules))
                }
            }
            saveRules(all)
        }
    }

    public func removeRule(id: UUID) {
        withLock {
            var all = rules()
            all.removeAll { $0.id == id }
            saveRules(all)
        }
    }

    public func setRuleEnabled(id: UUID, enabled: Bool) {
        withLock {
            var all = rules()
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            all[i].enabled = enabled
            saveRules(all)
        }
    }

    public func clearRules() {
        withLock { defaults.removeObject(forKey: Self.rulesKey) }
    }

    private func saveRules(_ rules: [CorrectionRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.rulesKey)
    }

    // MARK: - Learning from edits

    /// Maximum words on either side of a learned substitution.
    private static let maxRuleWords = 3

    /// A rule auto-applies after this many sightings (immediately when the
    /// replacement is a known vocabulary term or proper noun).
    private static let ruleActivationSightings = 2

    /// If the user's edit turns a rule's replacement back into its match,
    /// the rule was wrong for them — stop applying it. Batched into one
    /// load-modify-write (caller already holds the lock).
    private func disableReversedRules(raw: String, edited: String) {
        let rawLower = raw.lowercased()
        let editedLower = edited.lowercased()
        var all = rules()
        var changed = false
        for i in all.indices where all[i].enabled {
            if rawLower.contains(all[i].replacement.lowercased()),
               editedLower.contains(all[i].match) {
                all[i].enabled = false
                changed = true
            }
        }
        if changed { saveRules(all) }
    }

    /// Word-align raw vs edited (LCS diff); each substitution segment of
    /// ≤3 words per side becomes a correction rule, and proper-noun
    /// replacements are promoted to vocabulary. Returns what the edit
    /// changed about future behaviour, for user-facing surfacing.
    @discardableResult
    private func learnFromEdit(raw: String, edited: String) -> LearningOutcome {
        var outcome = LearningOutcome()
        let rawTokens = Self.tokenize(raw)
        let editedTokens = Self.tokenize(edited)
        guard !rawTokens.isEmpty, !editedTokens.isEmpty else { return outcome }

        let existingTerms = Set(
            (vocabularyManager?.entries() ?? []).map { $0.term.lowercased() }
        )

        let alignment = Self.align(rawTokens.map(\.key), editedTokens.map(\.key))

        // Case-only fixes at matched positions ("databid" → "DataBid") never
        // appear as mismatches — the keys are equal, so the LCS walk treats
        // them as aligned. Promote these to vocabulary — but only when the
        // edited form actually looks like a proper noun. Sentence
        // restructuring flips ordinary words between "Voice" and "voice";
        // production data showed those flooding the vocabulary with
        // lowercase common words that waste the prompt-token budget.
        if let vocab = vocabularyManager {
            for (i, j) in alignment.matches {
                let rawTok = rawTokens[i], editedTok = editedTokens[j]
                guard rawTok.display != editedTok.display,
                      !existingTerms.contains(editedTok.display.lowercased()),
                      // Text-initial capitalization is convention, not
                      // signal — there, only CamelCase/ALLCAPS qualify.
                      ProperNoun.looksLikeProperNoun(editedTok.display, isSentenceInitial: j == 0),
                      !fuzzyMatchesExistingTerm(editedTok.display) else { continue }
                if vocab.addEntry(VocabularyEntry(term: editedTok.display, category: ProperNoun.guessCategory(editedTok.display))) {
                    outcome.promotedTerms.append(editedTok.display)
                }
            }
        }

        for (rawRange, editedRange) in alignment.mismatches {
            // Substitutions only — pure insertions/deletions aren't
            // "X misheard as Y" evidence.
            guard !rawRange.isEmpty, !editedRange.isEmpty,
                  rawRange.count <= Self.maxRuleWords,
                  editedRange.count <= Self.maxRuleWords else { continue }

            let match = rawTokens[rawRange].map(\.key).joined(separator: " ")
            let replacement = editedTokens[editedRange].map(\.display).joined(separator: " ")
            guard !match.isEmpty, !replacement.isEmpty else { continue }
            // Case-only difference (equal keys) is handled by the matched-pairs
            // pass above, not as a rule.
            guard match != replacement.lowercased() else { continue }

            // Vocabulary promotion for single-word proper-noun replacements.
            // Skip candidates that fuzzy-match an existing term: promoting
            // "Sussurus" beside "Susurrus" pollutes the vocab with typo
            // variants and splits usage stats between them.
            var replacementKnown = existingTerms.contains(replacement.lowercased())
            if editedRange.count == 1, let vocab = vocabularyManager, !replacementKnown {
                let word = editedTokens[editedRange.lowerBound].display
                if ProperNoun.looksLikeProperNoun(word), !fuzzyMatchesExistingTerm(word) {
                    if vocab.addEntry(VocabularyEntry(term: word, category: ProperNoun.guessCategory(word))) {
                        outcome.promotedTerms.append(word)
                    }
                    replacementKnown = true
                }
            }

            // A match made entirely of common English words ("and while")
            // that maps to a *different* word will collide with legitimate
            // speech — never fast-path activate it; require the second
            // sighting. Join/casing fixes ("mark logic" → "MarkLogic",
            // same letters) stay on the fast path.
            let matchIsCommonPhrase = Self.isRiskyCommonPhraseMatch(match: match, replacement: replacement)

            let wasEnabled = rules().first(where: { $0.match == match })?.enabled ?? false

            let rule = CorrectionRule(
                match: match,
                replacement: replacement,
                enabled: replacementKnown && !matchIsCommonPhrase
            )
            addRule(rule)
            // Second sighting activates.
            if let stored = rules().first(where: { $0.match == rule.match }),
               stored.hitCount >= Self.ruleActivationSightings, !stored.enabled {
                setRuleEnabled(id: stored.id, enabled: true)
            }
            // Report rules that this edit switched from inert to active —
            // they'll now rewrite future transcriptions.
            if !wasEnabled,
               let final = rules().first(where: { $0.match == rule.match }),
               final.enabled {
                outcome.activatedRules.append(final)
            }
        }
        return outcome
    }

    /// Whether a promotion candidate is a near-duplicate (same phonetic
    /// key, tiny edit distance) of a term already in the vocabulary.
    private func fuzzyMatchesExistingTerm(_ candidate: String) -> Bool {
        guard let vocab = vocabularyManager else { return false }
        let normalized = Self.normalizeForFuzzy(candidate)
        return vocab.entries().contains {
            TranscriptCorrector.isFuzzyMatch(normalized, Self.normalizeForFuzzy($0.term))
        }
    }

    private static func normalizeForFuzzy(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A rule whose match is entirely common English words AND whose
    /// replacement isn't just a joined/recased form of those words (same
    /// letters) would rewrite legitimate speech — "and while" → "Anwar"
    /// must not activate off one sighting, but "mark logic" → "MarkLogic"
    /// is safe.
    static func isRiskyCommonPhraseMatch(match: String, replacement: String) -> Bool {
        guard normalizeForFuzzy(match) != normalizeForFuzzy(replacement) else { return false }
        return match
            .split(separator: " ")
            .allSatisfy { CommonWords.contains(String($0)) }
    }

    // MARK: - One-time cleanup of pre-guard learning data

    private static let learningQualityMigrationKey = "learningQualityMigration1"

    /// Repairs data written before the promotion/activation guards existed:
    /// removes all-lowercase common-word vocabulary entries (sentence-case
    /// churn, not terms) and de-activates single-sighting rules whose match
    /// is entirely common words (e.g. "and while" → "Anwar" hijacking
    /// ordinary speech). Runs once; returns what it changed for logging.
    @discardableResult
    public func runLearningQualityMigration() -> (removedTerms: [String], disabledRules: [String]) {
        guard !defaults.bool(forKey: Self.learningQualityMigrationKey) else { return ([], []) }

        var removedTerms: [String] = []
        var disabledRules: [String] = []
        withLock {
            if let vocab = vocabularyManager {
                let junk = vocab.entries().filter { entry in
                    entry.term == entry.term.lowercased()
                        && CommonWords.contains(Self.normalizeForFuzzy(entry.term))
                }
                for entry in junk {
                    vocab.removeEntry(id: entry.id)
                    removedTerms.append(entry.term)
                }
            }

            var all = rules()
            var changed = false
            // Learned rules only — manual rules are a deliberate user choice.
            for i in all.indices where all[i].enabled
                && all[i].source == .learned
                && all[i].hitCount < Self.ruleActivationSightings {
                if Self.isRiskyCommonPhraseMatch(match: all[i].match, replacement: all[i].replacement) {
                    all[i].enabled = false
                    disabledRules.append("\(all[i].match)→\(all[i].replacement)")
                    changed = true
                }
            }
            if changed { saveRules(all) }

            defaults.set(true, forKey: Self.learningQualityMigrationKey)
        }
        return (removedTerms, disabledRules)
    }

    // MARK: - Word alignment

    struct EditToken {
        /// Original word with edge punctuation stripped.
        let display: String
        /// Lowercased comparison key.
        let key: String
    }

    static func tokenize(_ text: String) -> [EditToken] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let display = String(raw).trimmingCharacters(
                in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted
            )
            guard !display.isEmpty else { return nil }
            return EditToken(display: display, key: display.lowercased())
        }
    }

    /// LCS word alignment of `a` and `b`: matched index pairs (equal at that
    /// position) and contiguous mismatch regions between them.
    static func align(
        _ a: [String],
        _ b: [String]
    ) -> (matches: [(Int, Int)], mismatches: [(Range<Int>, Range<Int>)]) {
        let n = a.count, m = b.count
        var dp = Array(repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : Swift.max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var matches: [(Int, Int)] = []
        var mismatches: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                matches.append((i, j))
                i += 1; j += 1
                continue
            }
            let si = i, sj = j
            while i < n || j < m {
                if i < n, j < m, a[i] == b[j] { break }
                if j == m || (i < n && dp[i + 1][j] >= dp[i][j + 1]) {
                    i += 1
                } else {
                    j += 1
                }
            }
            mismatches.append((si..<i, sj..<j))
        }
        return (matches, mismatches)
    }

    /// Contiguous mismatch regions from an LCS word alignment of `a` and `b`.
    static func mismatchRegions(_ a: [String], _ b: [String]) -> [(Range<Int>, Range<Int>)] {
        align(a, b).mismatches
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
