import Foundation
import Testing
@testable import SusurrusKit

@Suite("HotkeyCombo Model Tests")
struct HotkeyComboModelTests {

    @Test("Codable roundtrip preserves keyCode and modifiers")
    func codableRoundtrip() throws {
        let combo = HotkeyCombo(keyCode: 0x31, modifiers: 0x0800)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyCombo.self, from: data)
        #expect(decoded == combo)
    }

    @Test("Codable roundtrip with zero values")
    func codableRoundtripZero() throws {
        let combo = HotkeyCombo(keyCode: 0, modifiers: 0)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyCombo.self, from: data)
        #expect(decoded == combo)
    }

    @Test("withLLM combo has different keyCode or modifiers than default")
    func withLLMDiffersFromDefault() {
        // Just verify they're not identical — the exact values may change
        #expect(HotkeyCombo.default != HotkeyCombo.withLLM)
    }

    @Test("HotkeyCombo is Sendable")
    func sendable() {
        // This test compiles only if HotkeyCombo conforms to Sendable
        let combo = HotkeyCombo(keyCode: 1, modifiers: 2)
        let closure: @Sendable () -> HotkeyCombo = { combo }
        #expect(closure() == combo)
    }
}

@Suite("GlobalHotkeyService Basic Tests")
struct GlobalHotkeyServiceBasicTests {

    @Test("isRegistered returns false initially")
    func notRegisteredInitially() async {
        let service = GlobalHotkeyService()
        let registered = await service.isRegistered()
        #expect(registered == false)
    }

    @Test("unregister without prior register does not crash")
    func unregisterWithoutRegister() async {
        let service = GlobalHotkeyService()
        await service.unregister()
        let registered = await service.isRegistered()
        #expect(registered == false)
    }

    @Test("unregister after unregister is safe")
    func doubleUnregister() async {
        let service = GlobalHotkeyService()
        await service.unregister()
        await service.unregister()
        #expect(await service.isRegistered() == false)
    }
}
