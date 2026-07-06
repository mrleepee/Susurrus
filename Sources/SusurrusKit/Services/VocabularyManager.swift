import Foundation

/// Concrete vocabulary manager persisting to UserDefaults.
/// Supports both flat words (legacy) and categorized entries (F9).
/// Automatically migrates flat words to categorized entries on first access.
public final class VocabularyManager: VocabularyManaging, @unchecked Sendable {
    private let defaults: UserDefaults
    private let flatKey = "vocabularyWords"
    private let entriesKey = "vocabularyEntries"
    private let skipSeed: Bool

    /// Serializes load-modify-write on the entries key so the background
    /// dictation-stop task (`recordUsage`) and main-thread edits/promotions
    /// (`addEntry`) can't clobber each other. Recursive so `importCSV` can
    /// call `addEntry` on the same thread without deadlocking.
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Shared production instance backed by `UserDefaults.standard`. All app
    /// and view call sites must use this so they share one lock — separate
    /// instances hitting the same keys would still lose updates.
    public static let shared = VocabularyManager()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.skipSeed = false
        migrateIfNeeded()
    }

    private init(defaults: UserDefaults, skipSeed: Bool) {
        self.defaults = defaults
        self.skipSeed = skipSeed
        migrateIfNeeded()
    }

    /// Factory for testing with an isolated UserDefaults suite (no seed data).
    public static func createForTesting() -> VocabularyManager {
        VocabularyManager(defaults: UserDefaults(suiteName: "com.susurrus.vocab.test.\(UUID().uuidString)")!, skipSeed: true)
    }

    // MARK: - Legacy flat-word API

    public func vocabularyWords() -> [String] {
        entries().map(\.term)
    }

    public func setVocabularyWords(_ words: [String]) {
        let newEntries = words.map { VocabularyEntry(term: $0, category: .custom) }
        setEntries(newEntries)
    }

    public func promptString() -> String {
        entries().map(\.term).joined(separator: ", ")
    }

    // MARK: - Categorized entries API

    public func entries() -> [VocabularyEntry] {
        guard let data = defaults.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
    }

    public func setEntries(_ entries: [VocabularyEntry]) {
        withLock {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            defaults.set(data, forKey: entriesKey)
        }
    }

    /// Add an entry unless a term already exists that differs only by case
    /// (UI, CSV import, and auto-promotion can all race to add the same
    /// term). Returns whether the entry was added.
    @discardableResult
    public func addEntry(_ entry: VocabularyEntry) -> Bool {
        withLock {
            var current = entries()
            let key = entry.term.lowercased()
            guard !current.contains(where: { $0.term.lowercased() == key }) else {
                return false
            }
            current.append(entry)
            setEntries(current)
            return true
        }
    }

    public func removeEntry(id: UUID) {
        withLock {
            var current = entries()
            current.removeAll { $0.id == id }
            setEntries(current)
        }
    }

    public func llmContextString() -> String {
        Self.contextString(for: entries())
    }

    /// Vocabulary guidance filtered to terms plausibly present in the given
    /// transcript (exact-normalized or phonetic n-gram hit). Dumping the
    /// whole vocabulary invites the LLM to inject terms that weren't spoken.
    public func llmContextString(relevantTo text: String) -> String {
        let all = entries()
        guard !all.isEmpty else { return "" }

        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        var norms: Set<String> = []
        var fuzzyCandidates: [String] = []
        for n in 1...3 {
            guard words.count >= n else { break }
            for start in 0...(words.count - n) {
                let norm = TranscriptCorrector.normalize(words[start..<(start + n)].joined())
                guard norm.count >= 2, norms.insert(norm).inserted else { continue }
                if norm.count >= TranscriptCorrector.minFuzzyLength {
                    fuzzyCandidates.append(norm)
                }
            }
        }

        let relevant = all.filter { entry in
            let norm = TranscriptCorrector.normalize(entry.term)
            guard norm.count >= 2 else { return false }
            if norms.contains(norm) { return true }
            guard norm.count >= TranscriptCorrector.minFuzzyLength else { return false }
            return fuzzyCandidates.contains { TranscriptCorrector.isFuzzyMatch($0, norm) }
        }
        return Self.contextString(for: relevant)
    }

    private static func contextString(for entries: [VocabularyEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        return entries.map { entry in
            "\"\(entry.term)\" \(entry.category.llmInstruction)"
        }.joined(separator: ". ") + "."
    }

    /// Bump usage stats for every entry whose term appears (normalized)
    /// in the given final text. Usage feeds the prompt-token ranking.
    public func recordUsage(in text: String) {
        // Compute the match set outside the lock (pure work), then apply
        // the read-modify-write atomically so a concurrent addEntry/edit
        // isn't lost.
        let words = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        var norms: Set<String> = []
        for n in 1...3 {
            guard words.count >= n else { break }
            for start in 0...(words.count - n) {
                norms.insert(TranscriptCorrector.normalize(words[start..<(start + n)].joined()))
            }
        }
        guard !norms.isEmpty else { return }

        withLock {
            var all = entries()
            guard !all.isEmpty else { return }
            var changed = false
            for i in all.indices where norms.contains(TranscriptCorrector.normalize(all[i].term)) {
                all[i].useCount = (all[i].useCount ?? 0) + 1
                all[i].lastUsedAt = Date()
                changed = true
            }
            if changed {
                setEntries(all)
            }
        }
    }

    // MARK: - CSV Import/Export

    /// Export all entries as CSV string: "Word,Category\n..."
    public func exportCSV() -> String {
        var lines = ["Word,Category"]
        for entry in entries() {
            // Wrap in quotes if term contains a comma
            let term = entry.term.contains(",") ? "\"\(entry.term)\"" : entry.term
            lines.append("\(term),\(entry.category.displayName)")
        }
        return lines.joined(separator: "\n")
    }

    /// Import entries from CSV string. Expects header row "Word,Category".
    /// Returns the number of entries imported.
    @discardableResult
    public func importCSV(_ csv: String) -> Int {
        var lines = csv.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Skip header if present
        if let first = lines.first, first.lowercased().hasPrefix("word") {
            lines.removeFirst()
        }

        // Whole import is one atomic section so a concurrent dictation-stop
        // usage write can't interleave and drop rows.
        return withLock {
        var imported = 0
        for line in lines {
            // Handle quoted values
            var columns: [String] = []
            var current = ""
            var inQuotes = false
            for char in line {
                if char == "\"" {
                    inQuotes.toggle()
                } else if char == "," && !inQuotes {
                    columns.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(char)
                }
            }
            columns.append(current.trimmingCharacters(in: .whitespaces))

            guard columns.count >= 2 else { continue }
            let term = columns[0]
            let categoryString = columns[1]

            guard !term.isEmpty else { continue }

            // Match category by displayName or rawValue (case-insensitive)
            let category = VocabularyCategory.allCases.first { cat in
                cat.displayName.caseInsensitiveCompare(categoryString) == .orderedSame ||
                cat.rawValue.caseInsensitiveCompare(categoryString) == .orderedSame
            } ?? .custom

            if addEntry(VocabularyEntry(term: term, category: category)) {
                imported += 1
            }
        }
        return imported
        }
    }

    // MARK: - Migration

    /// Migrate flat vocabulary words to categorized entries if needed.
    /// Runs once on init. After migration, deletes the old key.
    private func migrateIfNeeded() {
        // Already migrated
        if defaults.data(forKey: entriesKey) != nil { return }

        // Check for legacy flat words
        let flatWords = defaults.stringArray(forKey: flatKey) ?? []
        guard !flatWords.isEmpty else {
            // No legacy data — initialize with defaults (skip in test mode)
            if !skipSeed {
                seedDefaultEntries()
            } else {
                setEntries([])
            }
            return
        }

        // Migrate each word to a custom-category entry
        let migrated = flatWords.map { VocabularyEntry(term: $0, category: .custom) }
        setEntries(migrated)
        defaults.removeObject(forKey: flatKey)
    }

    /// Seed default vocabulary entries on first launch.
    private func seedDefaultEntries() {
        let csv = """
        Word,Category
        Balvinder,Person
        Carina,Person
        Datavid,Company
        MiroClaw,Product
        Silvia,Person
        superwhisper,Product
        Susurrus,Product
        Harnadh,Person
        Elaine,Person
        SAAS,Acronym
        Trust Signals,Project
        RNs,Acronym
        242 C3,Project
        react-dev,Technical
        CAS,Acronym
        Lead's,Project
        Subha,Person
        Jayendra,Person
        BioFinder,Product
        QAS,Acronym
        prescribers,Project
        Evoca,Product
        SPARQL,Technical
        Lech,Person
        SciFinder,Product
        MatFinder,Product
        APIs,Technical
        MarkLogic,Technical
        Harandh,Person
        CoRB,Technical
        Schengen,Place
        Gaurav,Person
        """
        importCSV(csv)
    }
}
