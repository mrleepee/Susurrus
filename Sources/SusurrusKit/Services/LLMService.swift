import Foundation

/// LLM post-processing service using Anthropic-compatible API.
/// Reads configuration from (in priority order):
/// 1. UserDefaults (set via Preferences UI)
/// 2. Bundled .env file (Contents/Resources/.env)
/// 3. Hardcoded defaults
public final class LLMService: LLMProcessing, @unchecked Sendable {
    private let session: URLSession
    /// Optional override for the API key. When set, overrides all config sources
    /// (UserDefaults, .env file). Intended for testing and internal use.
    private let apiKeyOverride: String?

    public init(session: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.session = session
        self.apiKeyOverride = apiKeyOverride
    }

    // MARK: - Configuration

    private struct Config {
        let apiKey: String
        let model: String
        let endpoint: String
    }

    private static func loadEnvFile() -> [String: String] {
        var env: [String: String] = [:]
        // Check bundle Resources first, then project root
        let candidates: [URL] = {
            var paths: [URL] = []
            if let bundleURL = Bundle.main.url(forResource: ".env", withExtension: nil, subdirectory: nil) {
                paths.append(bundleURL)
            }
            // Fallback: look next to the executable (for development)
            if let execPath = Bundle.main.executablePath {
                let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()
                paths.append(execDir.appendingPathComponent("../Resources/.env"))
            }
            return paths
        }()

        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                env[key] = value
            }
            if !env.isEmpty { break }
        }
        return env
    }

    private func resolveConfig() -> Config {
        let defaults = UserDefaults.standard
        let env = Self.loadEnvFile()

        let apiKey = apiKeyOverride ?? defaults.string(forKey: "llmApiKey") ?? env["LLM_API_KEY"] ?? ""
        let model = defaults.string(forKey: "llmModel") ?? env["LLM_MODEL"] ?? "MiniMax-M2.5"
        let endpoint = defaults.string(forKey: "llmEndpoint") ?? env["LLM_ENDPOINT"] ?? "https://api.minimax.io/anthropic/v1/messages"

        return Config(apiKey: apiKey, model: model, endpoint: endpoint)
    }

    // MARK: - Process

    public func process(text: String, systemPrompt: String) async throws -> String {
        let config = resolveConfig()

        guard !config.apiKey.isEmpty else {
            throw LLMError.requestFailed("API key not configured. Set it in Preferences > LLM or in the .env file.")
        }

        guard let endpointURL = URL(string: config.endpoint) else {
            throw LLMError.requestFailed("Invalid endpoint URL: \(config.endpoint)")
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResult
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": max(text.count * 2, 512),
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        // Anthropic response format: content is an array of blocks
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse
        }

        // Take the first "text" block (skip "thinking" blocks)
        for block in contentBlocks {
            if block["type"] as? String == "text",
               let blockText = block["text"] as? String,
               !blockText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return blockText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw LLMError.emptyResult
    }
}
