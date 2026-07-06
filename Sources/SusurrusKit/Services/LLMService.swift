import Foundation

/// Which LLM backend handles post-processing.
public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// Try the local endpoint first, fall back to cloud when configured.
    case auto
    /// Local OpenAI-compatible server only (LM Studio, Ollama).
    case local
    /// Anthropic-compatible cloud endpoint only.
    case cloud

    /// Label for the Preferences picker (driven by `allCases`).
    public var displayName: String {
        switch self {
        case .auto: return "Auto (local, then cloud)"
        case .local: return "Local only"
        case .cloud: return "Cloud only"
        }
    }
}

/// LLM post-processing service.
///
/// Local path: OpenAI-compatible chat completions (LM Studio, Ollama) —
/// private, free, fast on Apple Silicon. Cloud path: Anthropic-compatible
/// API. Configuration priority for the cloud path:
/// 1. macOS Keychain (API key — never stored in UserDefaults or .env)
/// 2. UserDefaults (model, endpoint)
/// 3. Bundled .env file (model, endpoint only — NOT the API key)
/// 4. Hardcoded defaults
public final class LLMService: LLMProcessing, @unchecked Sendable {
    private let session: URLSession
    private let keychain: KeychainService

    /// Optional override for the API key. When set, overrides all config sources.
    /// Intended for testing only — do not use in production.
    private let apiKeyOverride: String?

    public init(session: URLSession = .shared, apiKeyOverride: String? = nil) {
        self.session = session
        self.keychain = KeychainService()
        self.apiKeyOverride = apiKeyOverride
    }

    // MARK: - Configuration

    private struct Config {
        let apiKey: String
        let model: String
        let endpoint: String
        let provider: LLMProvider
        let localEndpoint: String
        let localModel: String
    }

    public static let defaultLocalEndpoint = "http://localhost:1234/v1/chat/completions"

    /// Loads .env file from the bundle's Resources directory.
    /// Used only for non-sensitive config (model, endpoint).
    /// The API key is NEVER loaded from .env in production.
    private static func loadEnvFile() -> [String: String] {
        var env: [String: String] = [:]
        let candidates: [URL] = {
            var paths: [URL] = []
            if let bundleURL = Bundle.main.url(forResource: ".env", withExtension: nil, subdirectory: nil) {
                paths.append(bundleURL)
            }
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

        // API key: Keychain (primary), apiKeyOverride (testing), else ""
        // Never fall back to .env or UserDefaults for the API key.
        let apiKey = apiKeyOverride ?? keychain.get("llmApiKey") ?? ""

        // Model and endpoint: UserDefaults with .env and hardcoded defaults as fallbacks
        let model = defaults.string(forKey: "llmModel") ?? env["LLM_MODEL"] ?? "MiniMax-M2.5"
        let endpoint = defaults.string(forKey: "llmEndpoint") ?? env["LLM_ENDPOINT"] ?? "https://api.minimax.io/anthropic/v1/messages"

        // Defaults to cloud (legacy behaviour): trying an unconfigured local
        // endpoint first would add a multi-second hang on every dictation
        // for anyone who hasn't set up LM Studio/Ollama. Auto/Local are
        // explicit opt-ins from Preferences.
        let provider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .cloud
        let localEndpoint = defaults.string(forKey: "llmLocalEndpoint") ?? Self.defaultLocalEndpoint
        let localModel = defaults.string(forKey: "llmLocalModel") ?? ""

        return Config(
            apiKey: apiKey,
            model: model,
            endpoint: endpoint,
            provider: provider,
            localEndpoint: localEndpoint,
            localModel: localModel
        )
    }

    // MARK: - Process

    public func process(text: String, systemPrompt: String) async throws -> String {
        let config = resolveConfig()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResult
        }

        switch config.provider {
        case .local:
            // User explicitly chose local and is willing to wait for it.
            return try await processLocal(text: text, systemPrompt: systemPrompt, config: config, timeout: Self.localTimeout)
        case .cloud:
            return try await processCloud(text: text, systemPrompt: systemPrompt, config: config)
        case .auto:
            do {
                // Fail fast to cloud if no local server answers — don't make
                // every dictation eat the full local timeout when LM Studio
                // isn't running.
                return try await processLocal(text: text, systemPrompt: systemPrompt, config: config, timeout: Self.autoProbeTimeout)
            } catch {
                guard !config.apiKey.isEmpty else { throw error }
                return try await processCloud(text: text, systemPrompt: systemPrompt, config: config)
            }
        }
    }

    /// Full local-request timeout when the user has explicitly chosen the
    /// local provider (seconds).
    private static let localTimeout: TimeInterval = 10
    /// Short local-probe timeout in `.auto` mode so an absent local server
    /// falls through to cloud quickly (seconds).
    private static let autoProbeTimeout: TimeInterval = 2

    /// OpenAI-compatible chat completions against a local server
    /// (LM Studio :1234, Ollama :11434/v1). Short timeout — a local server
    /// that isn't up should fail fast, not hang the paste.
    private func processLocal(text: String, systemPrompt: String, config: Config, timeout: TimeInterval) async throws -> String {
        guard let endpointURL = URL(string: config.localEndpoint) else {
            throw LLMError.requestFailed("Invalid local endpoint URL: \(config.localEndpoint)")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0,
            "max_tokens": max(text.count * 2, 512)
        ]
        // LM Studio serves whichever model is loaded when the name is
        // omitted; only pin one when the user configured it.
        if !config.localModel.isEmpty {
            body["model"] = config.localModel
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw LLMError.requestFailed("Local LLM HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResult }
        return trimmed
    }

    /// Anthropic-compatible cloud endpoint.
    private func processCloud(text: String, systemPrompt: String, config: Config) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw LLMError.requestFailed("API key not configured. Set it in Preferences > LLM.")
        }

        guard let endpointURL = URL(string: config.endpoint) else {
            throw LLMError.requestFailed("Invalid endpoint URL: \(config.endpoint)")
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
            "temperature": 0,
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

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse
        }

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
