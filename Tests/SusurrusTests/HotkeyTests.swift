import Testing
@testable import SusurrusKit

/// Mutable reference wrapper for tracking handler calls in @Sendable closures.
final class Trigger: @unchecked Sendable {
    var fired = false
}

/// Mock hotkey manager for testing without Carbon.
actor MockHotkeyManager: HotkeyManaging {
    var registeredFlag = false
    var currentCombo: HotkeyCombo?
    var handler: (@Sendable () -> Void)?
    var registerCallCount = 0
    var unregisterCallCount = 0

    func register(combo: HotkeyCombo, handler: @Sendable @escaping () -> Void) async throws {
        currentCombo = combo
        self.handler = handler
        registeredFlag = true
        registerCallCount += 1
    }

    func unregister() async {
        handler = nil
        currentCombo = nil
        registeredFlag = false
        unregisterCallCount += 1
    }

    func isRegistered() async -> Bool {
        registeredFlag
    }

    /// Simulate the hotkey being pressed.
    func simulatePress() async {
        handler?()
    }
}

@Suite("Hotkey Tests")
struct HotkeyTests {

    @Test("Register sets registered state")
    func registerSetsState() async throws {
        let manager = MockHotkeyManager()
        #expect(await manager.isRegistered() == false)

        try await manager.register(combo: .default) {}
        #expect(await manager.isRegistered() == true)
        #expect(await manager.registerCallCount == 1)
    }

    @Test("Unregister clears state")
    func unregisterClearsState() async throws {
        let manager = MockHotkeyManager()
        try await manager.register(combo: .default) {}
        await manager.unregister()

        #expect(await manager.isRegistered() == false)
        #expect(await manager.unregisterCallCount == 1)
    }

    @Test("Hotkey press calls handler")
    func pressCallsHandler() async throws {
        let manager = MockHotkeyManager()
        let trigger = Trigger()

        try await manager.register(combo: .default) { trigger.fired = true }

        await manager.simulatePress()
        #expect(trigger.fired == true)
    }

    @Test("Re-register replaces previous handler")
    func reregisterReplaces() async throws {
        let manager = MockHotkeyManager()
        let first = Trigger()
        let second = Trigger()

        try await manager.register(combo: .default) { first.fired = true }
        try await manager.register(combo: .default) { second.fired = true }

        await manager.simulatePress()
        #expect(first.fired == false)
        #expect(second.fired == true)
    }

    @Test("Unregister then press does nothing")
    func unregisterThenPress() async throws {
        let manager = MockHotkeyManager()
        let trigger = Trigger()

        try await manager.register(combo: .default) { trigger.fired = true }
        await manager.unregister()
        await manager.simulatePress()

        #expect(trigger.fired == false)
    }

    @Test("HotkeyCombo equality")
    func comboEquality() {
        let a = HotkeyCombo(keyCode: 0, modifiers: 0)
        let b = HotkeyCombo(keyCode: 0, modifiers: 0)
        let c = HotkeyCombo(keyCode: 1, modifiers: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("HotkeyCombo default value")
    func defaultCombo() {
        let `default` = HotkeyCombo.default
        #expect(`default`.keyCode == 0)
        #expect(`default`.modifiers == 0)
    }

    @Test("Hotkey combo persists to currentCombo")
    func comboPersisted() async throws {
        let manager = MockHotkeyManager()
        let combo = HotkeyCombo(keyCode: 7, modifiers: 0x0100)
        try await manager.register(combo: combo) {}
        let stored = await manager.currentCombo
        #expect(stored == combo)
    }
}
