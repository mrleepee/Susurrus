import Foundation

/// Manages transcription history, persisted to UserDefaults.
public final class TranscriptionHistoryManager: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let historyKey = "transcriptionHistory"
    public static let maxItems = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Add a new transcription to history.
    public func add(_ text: String) {
        var items = loadAll()
        items.insert(TranscriptionHistoryItem(text: text), at: 0)
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        save(items)
    }

    /// Get all history items (newest first).
    public func items() -> [TranscriptionHistoryItem] {
        loadAll()
    }

    /// Clear all history.
    public func clear() {
        defaults.removeObject(forKey: Self.historyKey)
    }

    private func loadAll() -> [TranscriptionHistoryItem] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? JSONDecoder().decode([TranscriptionHistoryItem].self, from: data)) ?? []
    }

    private func save(_ items: [TranscriptionHistoryItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    /// Factory for testing with isolated UserDefaults.
    public static func createForTesting() -> TranscriptionHistoryManager {
        TranscriptionHistoryManager(defaults: UserDefaults(suiteName: "com.susurrus.history.test.\(UUID().uuidString)")!)
    }
}
