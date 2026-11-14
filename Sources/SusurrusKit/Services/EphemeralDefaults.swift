import Foundation

/// Throwaway `UserDefaults` for tests, held in memory only.
///
/// A real suite leaves a plist in ~/Library/Preferences for every instance
/// that is written to, and `removePersistentDomain(forName:)` only empties
/// that file rather than deleting it: the test factories had left about
/// 21,500 behind. Nothing here touches disk.
public enum EphemeralDefaults {
    /// A fresh, empty store. `label` only documents what it is for.
    public static func make(_ label: String) -> UserDefaults {
        InMemoryDefaults()
    }
}

/// `UserDefaults` whose typed accessors (`bool`, `string`, `data`, …) all
/// route through the three overrides below.
private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        storage[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        storage[defaultName] = nil
    }
}
