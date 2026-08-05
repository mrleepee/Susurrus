import Foundation

/// Manages transcription history, persisted to UserDefaults.
public final class TranscriptionHistoryManager: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let historyKey = "transcriptionHistory"
    public static let maxItems = 200

    /// Optional correction learning manager for recording edits.
    public var correctionManager: (any CorrectionLearning)?

    /// Serializes load-modify-write on the history key: the background
    /// dictation-stop task calls `add` while UI edits (History window, Fix
    /// Last Dictation) call `updateText`.
    private let lock = NSRecursiveLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Shared production instance backed by `UserDefaults.standard`.
    public static let shared = TranscriptionHistoryManager()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Add a new transcription to history (backward compatible).
    public func add(_ text: String) {
        add(text, rawText: nil)
    }

    /// Add a new transcription to history with raw ASR text.
    public func add(_ text: String, rawText: String?) {
        withLock {
            var items = loadAll()
            items.insert(TranscriptionHistoryItem(text: text, rawText: rawText), at: 0)
            if items.count > Self.maxItems {
                items = Array(items.prefix(Self.maxItems))
            }
            save(items)
        }
    }

    /// Update the text of an existing history item (user edit).
    /// Records the edit as a correction pair for F10.
    public func updateText(id: UUID, newText: String) {
        var recorded: (raw: String, edited: String)?
        withLock {
            var items = loadAll()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let oldText = items[index].text
            guard oldText != newText else { return }

            let updatedItem = items[index].withText(newText)
            items[index] = updatedItem
            save(items)

            // Record correction pair for F10
            let raw = updatedItem.rawText ?? oldText
            if raw != newText {
                recorded = (raw, newText)
            }
        }
        // Outside the lock: recordCorrection takes its own lock and may
        // fire user-facing callbacks.
        if let recorded {
            correctionManager?.recordCorrection(raw: recorded.raw, edited: recorded.edited)
        }
    }

    /// Get all history items (newest first).
    public func items() -> [TranscriptionHistoryItem] {
        loadAll()
    }

    /// Proper-noun-ish terms from recent dictations, newest first. Used as
    /// ASR bias candidates — "what have I been talking about lately" needs
    /// no setup from the user.
    ///
    /// Candidates are drawn from the last `itemLimit` dictations, but the
    /// casing evidence used to reject ordinary words is built from the *whole*
    /// history: whether the user writes "document" in lowercase is a fact about
    /// them, not about the last ten things they said, and the wider corpus
    /// makes the judgement on rare words far sooner.
    ///
    /// The window is 30 rather than 10 because `extractBiasTerms` now ranks by
    /// how many dictations contain a term, and repetition is unmeasurable
    /// across ten items — nearly every candidate appears exactly once, so
    /// ranking changes nothing. Measured over 60 dictations: ranking across 10
    /// left the junk share of prompt slots at 25%, unchanged; across 30 it fell
    /// to 11%.
    public func recentBiasTerms(
        itemLimit: Int = 30,
        termLimit: Int = 20,
        dictionary: EnglishDictionary = .shared
    ) -> [String] {
        let all = loadAll()
        let profile = CasingProfile.build(from: all.map(\.text))
        return ProperNoun.extractBiasTerms(
            from: all.prefix(itemLimit).map(\.text),
            limit: termLimit,
            excluding: ProperNoun.ordinaryWordExclusion(
                profile: profile,
                dictionary: dictionary
            )
        )
    }

    /// Clear all history.
    public func clear() {
        defaults.removeObject(forKey: Self.historyKey)
    }

    /// Factory for testing with isolated UserDefaults.
    public static func createForTesting() -> TranscriptionHistoryManager {
        TranscriptionHistoryManager(defaults: UserDefaults(suiteName: "com.susurrus.history.test.\(UUID().uuidString)")!)
    }

    private func loadAll() -> [TranscriptionHistoryItem] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data)) ?? []
    }

    private func save(_ items: [TranscriptionHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }
}
