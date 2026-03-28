import Testing
@testable import SusurrusKit

@Suite("HotkeyStorage Tests")
struct HotkeyStorageTests {

    private func makeStorage() -> HotkeyStorage {
        HotkeyStorage.createForTesting()
    }

    @Test("Fresh storage is not configured")
    func freshNotConfigured() {
        let storage = makeStorage()
        #expect(storage.isConfigured == false)
    }

    @Test("loadCombo returns nil when not configured")
    func loadWhenNotConfigured() {
        let storage = makeStorage()
        #expect(storage.loadCombo() == nil)
    }

    @Test("save then load returns same combo")
    func saveAndLoad() {
        let storage = makeStorage()
        let combo = HotkeyCombo(keyCode: 42, modifiers: 0x1100)

        storage.save(combo: combo)
        #expect(storage.isConfigured == true)

        let loaded = storage.loadCombo()
        #expect(loaded == combo)
    }

    @Test("clear removes configuration")
    func clearRemovesConfig() {
        let storage = makeStorage()
        storage.save(combo: .default)
        #expect(storage.isConfigured == true)

        storage.clear()
        #expect(storage.isConfigured == false)
        #expect(storage.loadCombo() == nil)
    }

    @Test("save overwrites previous combo")
    func saveOverwrites() {
        let storage = makeStorage()
        let first = HotkeyCombo(keyCode: 1, modifiers: 0)
        let second = HotkeyCombo(keyCode: 2, modifiers: 0x100)

        storage.save(combo: first)
        storage.save(combo: second)

        let loaded = storage.loadCombo()
        #expect(loaded == second)
    }
}
