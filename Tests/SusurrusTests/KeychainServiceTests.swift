import Foundation
import Testing
@testable import SusurrusKit

@Suite("KeychainService Tests")
struct KeychainServiceTests {

    /// Use a unique service name per test to avoid collisions with real keychain data.
    private func makeService() -> KeychainService {
        KeychainService(service: "com.susurrus.test.\(UUID().uuidString)")
    }

    @Test("get returns nil for non-existent key")
    func getNonExistent() {
        let service = makeService()
        #expect(service.get("nonexistent-key-\(UUID().uuidString)") == nil)
    }

    @Test("set and get roundtrip")
    func setGetRoundtrip() {
        let service = makeService()
        let key = "test-key-\(UUID().uuidString)"
        defer { service.delete(key) }

        #expect(service.set("secret-value", for: key))
        #expect(service.get(key) == "secret-value")
    }

    @Test("set replaces existing value")
    func setReplaces() {
        let service = makeService()
        let key = "test-replace-\(UUID().uuidString)"
        defer { service.delete(key) }

        #expect(service.set("first", for: key))
        #expect(service.set("second", for: key))
        #expect(service.get(key) == "second")
    }

    @Test("delete removes key")
    func deleteRemoves() {
        let service = makeService()
        let key = "test-delete-\(UUID().uuidString)"

        service.set("value", for: key)
        #expect(service.delete(key))
        #expect(service.get(key) == nil)
    }

    @Test("delete returns true for non-existent key")
    func deleteNonExistent() {
        let service = makeService()
        #expect(service.delete("nonexistent-\(UUID().uuidString)"))
    }

    @Test("handles unicode values")
    func unicodeValues() {
        let service = makeService()
        let key = "test-unicode-\(UUID().uuidString)"
        defer { service.delete(key) }

        service.set("日本語テスト 🎵", for: key)
        #expect(service.get(key) == "日本語テスト 🎵")
    }

    @Test("handles empty string value")
    func emptyValue() {
        let service = makeService()
        let key = "test-empty-\(UUID().uuidString)"
        defer { service.delete(key) }

        service.set("", for: key)
        #expect(service.get(key) == "")
    }

    @Test("handles long values")
    func longValue() {
        let service = makeService()
        let key = "test-long-\(UUID().uuidString)"
        defer { service.delete(key) }

        let longValue = String(repeating: "a", count: 10000)
        service.set(longValue, for: key)
        #expect(service.get(key) == longValue)
    }

    @Test("different keys are independent")
    func differentKeys() {
        let service = makeService()
        let key1 = "test-key1-\(UUID().uuidString)"
        let key2 = "test-key2-\(UUID().uuidString)"
        defer { service.delete(key1); service.delete(key2) }

        service.set("value1", for: key1)
        service.set("value2", for: key2)
        #expect(service.get(key1) == "value1")
        #expect(service.get(key2) == "value2")
    }

    @Test("different services are independent")
    func differentServices() {
        let service1 = KeychainService(service: "com.susurrus.test.svc1.\(UUID().uuidString)")
        let service2 = KeychainService(service: "com.susurrus.test.svc2.\(UUID().uuidString)")
        let key = "same-key-\(UUID().uuidString)"
        defer { service1.delete(key); service2.delete(key) }

        service1.set("from-service1", for: key)
        service2.set("from-service2", for: key)
        #expect(service1.get(key) == "from-service1")
        #expect(service2.get(key) == "from-service2")
    }
}
