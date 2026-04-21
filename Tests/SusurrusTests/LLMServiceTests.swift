import Foundation
import Testing
@testable import SusurrusKit

// MARK: - Mock URL Protocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mockResponse: (Int, Data)?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // Capture body from either httpBody or httpBodyStream
        if let httpBody = request.httpBody {
            Self.lastRequestBody = httpBody
        } else if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read == 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastRequestBody = data
        }
        guard let (statusCode, data) = Self.mockResponse else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Build a minimal Anthropic-compatible success response with the given text.
private func makeSuccessData(text: String) -> Data {
    """
    {
      "content": [{"type": "text", "text": "\(text)"}],
      "model": "test-model",
      "stop_reason": "end_turn"
    }
    """.data(using: .utf8)!
}

// MARK: - LLMService HTTP Tests

@Suite("LLMService HTTP Tests", .serialized)
struct LLMServiceTests {

    @Test("Successful response returns extracted text from content blocks")
    func successfulResponse() async throws {
        MockURLProtocol.mockResponse = (200, makeSuccessData(text: "Cleaned transcription."))
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        let result = try await service.process(text: "raw transcription", systemPrompt: "clean up")

        #expect(result == "Cleaned transcription.")
    }

    @Test("HTTP 401 throws requestFailed with status code")
    func http401Throws() async {
        MockURLProtocol.mockResponse = (401, Data("unauthorized".utf8))
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        do {
            _ = try await service.process(text: "hello", systemPrompt: "prompt")
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            if case .requestFailed(let message) = error {
                #expect(message.contains("401"))
            } else {
                Issue.record("Expected requestFailed, got \(error)")
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Empty API key throws requestFailed about API key not configured")
    func emptyApiKeyThrows() async {
        // Use empty string override to guarantee no key regardless of machine Keychain state
        let service = LLMService(session: makeMockSession(), apiKeyOverride: "")
        do {
            _ = try await service.process(text: "hello", systemPrompt: "prompt")
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            if case .requestFailed(let message) = error {
                #expect(message.contains("API key not configured"))
            } else {
                Issue.record("Expected requestFailed, got \(error)")
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Empty content blocks throws emptyResult")
    func emptyContentBlocksThrow() async {
        let data = """
        { "content": [], "model": "test", "stop_reason": "end_turn" }
        """.data(using: .utf8)!
        MockURLProtocol.mockResponse = (200, data)
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        do {
            _ = try await service.process(text: "hello", systemPrompt: "prompt")
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            #expect(error == .emptyResult)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Non-JSON response throws error (invalidResponse or JSON parse error)")
    func nonJsonResponseThrows() async {
        MockURLProtocol.mockResponse = (200, Data("this is not json".utf8))
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        do {
            _ = try await service.process(text: "hello", systemPrompt: "prompt")
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            // If JSONSerialization succeeds but structurally wrong, we get invalidResponse
            #expect(error == .invalidResponse, "Expected invalidResponse, got \(error)")
        } catch {
            // JSONSerialization throws its own error for malformed JSON — also acceptable.
            // The key assertion: it did NOT silently succeed.
        }
    }

    @Test("apiKeyOverride is sent as x-api-key header")
    func apiKeyOverrideInHeader() async throws {
        MockURLProtocol.mockResponse = (200, makeSuccessData(text: "result"))
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "my-secret-key-123")
        _ = try await service.process(text: "hello", systemPrompt: "prompt")

        let capturedRequest = MockURLProtocol.lastRequest
        #expect(capturedRequest != nil)
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-api-key") == "my-secret-key-123")
    }

    @Test("UserDefaults model is used when set")
    func usesUserDefaultsModel() async throws {
        // Use an isolated UserDefaults suite to avoid polluting .standard
        let suiteName = "com.susurrus.test.llm.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.set("TestModel-Unit", forKey: "llmModel")
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        MockURLProtocol.mockResponse = (200, makeSuccessData(text: "result"))
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastRequestBody = nil
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let session = makeMockSession()
        // LLMService reads from UserDefaults.standard for model config.
        // We set on .standard with a unique key to avoid collisions, then clean up.
        let originalModel = UserDefaults.standard.string(forKey: "llmModel")
        UserDefaults.standard.set("TestModel-Unit", forKey: "llmModel")
        defer {
            if let original = originalModel {
                UserDefaults.standard.set(original, forKey: "llmModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "llmModel")
            }
        }

        let service = LLMService(session: session, apiKeyOverride: "test-key")

        _ = try await service.process(text: "hello", systemPrompt: "prompt")

        guard let bodyData = MockURLProtocol.lastRequestBody else {
            Issue.record("No request body captured")
            return
        }
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJson?["model"] as? String == "TestModel-Unit")
    }

    @Test("Request sends correct headers and body structure")
    func requestContractValidation() async throws {
        MockURLProtocol.mockResponse = (200, makeSuccessData(text: "result"))
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        _ = try await service.process(text: "input text", systemPrompt: "system prompt")

        let request = MockURLProtocol.lastRequest
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request?.httpMethod == "POST")

        guard let bodyData = MockURLProtocol.lastRequestBody else {
            Issue.record("No request body captured")
            return
        }
        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(body?["system"] as? String == "system prompt")
        #expect(body?["max_tokens"] as? Int != nil)
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] == "user")
        #expect(messages?[0]["content"] == "input text")
    }

    @Test("Content block with empty text is skipped, second valid block returned")
    func skipsEmptyContentBlocks() async throws {
        let data = """
        {
          "content": [
            {"type": "text", "text": "   "},
            {"type": "text", "text": "valid text"}
          ],
          "model": "test", "stop_reason": "end_turn"
        }
        """.data(using: .utf8)!
        MockURLProtocol.mockResponse = (200, data)
        defer { MockURLProtocol.mockResponse = nil; MockURLProtocol.lastRequest = nil; MockURLProtocol.lastRequestBody = nil }

        let service = LLMService(session: makeMockSession(), apiKeyOverride: "test-key")
        let result = try await service.process(text: "hello", systemPrompt: "prompt")
        #expect(result == "valid text")
    }
}
