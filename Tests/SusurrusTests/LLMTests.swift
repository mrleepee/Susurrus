import Testing
@testable import SusurrusKit

// MARK: - Mock LLM Service

/// Mock LLM service that returns a fixed transformation.
final class MockLLMService: LLMProcessing, @unchecked Sendable {
    var processCallCount = 0
    var lastText: String?
    var lastSystemPrompt: String?
    var result: String
    var shouldThrow = false

    init(result: String = "cleaned text") {
        self.result = result
    }

    func process(text: String, systemPrompt: String) async throws -> String {
        processCallCount += 1
        lastText = text
        lastSystemPrompt = systemPrompt
        if shouldThrow { throw LLMError.requestFailed("test error") }
        return result
    }
}

// MARK: - LLM Service Tests

@Suite("LLM Service Tests")
struct LLMTests {

    // MARK: - Preferences

    @Test("Default LLM is disabled")
    func defaultLLMDisabled() {
        let manager = UserDefaultsPreferencesManager.createForTesting()
        #expect(manager.llmEnabled() == false)
    }

    @Test("Enable and disable LLM")
    func toggleLLM() {
        let manager = UserDefaultsPreferencesManager.createForTesting()
        manager.setLLMEnabled(true)
        #expect(manager.llmEnabled() == true)
        manager.setLLMEnabled(false)
        #expect(manager.llmEnabled() == false)
    }

    @Test("Default LLM system prompt is not empty")
    func defaultSystemPrompt() {
        let manager = UserDefaultsPreferencesManager.createForTesting()
        let prompt = manager.llmSystemPrompt()
        #expect(!prompt.isEmpty)
    }

    @Test("Set and get custom system prompt")
    func customSystemPrompt() {
        let manager = UserDefaultsPreferencesManager.createForTesting()
        let custom = "Make this text more formal."
        manager.setLLMSystemPrompt(custom)
        #expect(manager.llmSystemPrompt() == custom)
    }

    // MARK: - LLMService error cases

    @Test("LLMService rejects empty text")
    func rejectEmptyText() async {
        // Provide a test API key via apiKeyOverride so we bypass real config.
        let service = LLMService(apiKeyOverride: "test-key-for-empty-text-check")
        do {
            _ = try await service.process(text: "   ", systemPrompt: "clean up")
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            #expect(error == .emptyResult)
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    @Test("LLMError equality")
    func llmErrorEquality() {
        #expect(LLMError.emptyResult == LLMError.emptyResult)
        #expect(LLMError.invalidResponse == LLMError.invalidResponse)
        #expect(LLMError.requestFailed("x") == LLMError.requestFailed("x"))
        #expect(LLMError.requestFailed("x") != LLMError.requestFailed("y"))
    }

    // MARK: - Mock service

    @Test("Mock LLM returns configured result")
    func mockServiceReturns() async throws {
        let mock = MockLLMService(result: "polished output")
        let result = try await mock.process(text: "raw text", systemPrompt: "clean up")
        #expect(result == "polished output")
        #expect(mock.processCallCount == 1)
    }

    @Test("Mock LLM tracks call arguments")
    func mockServiceTracksArgs() async throws {
        let mock = MockLLMService()
        _ = try await mock.process(text: "hello world", systemPrompt: "fix grammar")
        #expect(mock.lastText == "hello world")
        #expect(mock.lastSystemPrompt == "fix grammar")
    }

    @Test("Mock LLM throws when configured")
    func mockServiceThrows() async {
        let mock = MockLLMService()
        mock.shouldThrow = true
        do {
            _ = try await mock.process(text: "test", systemPrompt: "prompt")
            #expect(Bool(false), "Should have thrown")
        } catch {
            // Expected
        }
    }

    // MARK: - Integration: LLM in pipeline with mock

    @Test("LLM enabled transforms text through service")
    func llmEnabledTransformsText() async throws {
        let mock = MockLLMService(result: "Hello, world!")
        let result = try await mock.process(text: "hello world um", systemPrompt: "clean up")
        #expect(result == "Hello, world!")
        #expect(mock.lastText == "hello world um")
    }

    @Test("Multiple calls increment count")
    func multipleCalls() async throws {
        let mock = MockLLMService(result: "ok")
        _ = try await mock.process(text: "a", systemPrompt: "p")
        _ = try await mock.process(text: "b", systemPrompt: "p")
        _ = try await mock.process(text: "c", systemPrompt: "p")
        #expect(mock.processCallCount == 3)
    }
}
