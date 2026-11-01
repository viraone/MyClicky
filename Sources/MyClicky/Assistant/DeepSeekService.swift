import Foundation

/// Text-only client for DeepSeek's Anthropic-compatible Messages API.
///
/// The key and endpoint live outside the app. The key comes from the
/// Keychain first (account `deepseek`), then from
/// `~/.config/claude-provider/deepseek.env`. Nothing here logs the key, and
/// no error message carries it.
struct DeepSeekService {
    /// Everything one request needs. `displayName` is the model exactly as
    /// written in the env file; `apiModel` is what goes on the wire, with any
    /// bracket suffix (e.g. `[1m]`) removed.
    struct Configuration {
        let apiKey: String
        let baseURL: String
        let model: String

        /// The model name for the UI chip, suffix kept.
        var displayName: String { model }

        /// The model name for the request, suffix stripped.
        var apiModel: String {
            guard let bracket = model.firstIndex(of: "[") else { return model }
            let name = String(model[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? model : name
        }
    }

    static let defaultBaseURL = "https://api.deepseek.com/anthropic"
    static let defaultModel = "deepseek-flash"

    private static let systemPrompt = "You are Peeky Agent, a concise helpful assistant on the user's Mac. Plain text, no markdown tables."
    private static let maxTokens = 4_096
    private static let historyLimit = 6
    private static let timeout: TimeInterval = 60

    private static var environmentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("claude-provider")
            .appendingPathComponent("deepseek.env")
    }

    /// The model name the UI shows, read without touching the Keychain so a
    /// label can render without a keychain prompt. Keeps any `[..]` suffix.
    static var displayName: String {
        let env = readEnvironment()
        return nonEmpty(env["ANTHROPIC_MODEL"]) ?? defaultModel
    }

    /// Key first from the Keychain (account `deepseek`), then the env file.
    /// The endpoint and model always come from the env file, so a Keychain
    /// key can be paired with a custom base URL or model.
    nonisolated static func loadConfiguration() throws -> Configuration {
        let keychainKey = KeychainService.read(account: "deepseek")
        let env = readEnvironment()
        guard let key = keychainKey ?? nonEmpty(env["ANTHROPIC_AUTH_TOKEN"]) else {
            throw DeepSeekError.missingKey
        }
        return Configuration(
            apiKey: key,
            baseURL: nonEmpty(env["ANTHROPIC_BASE_URL"]) ?? defaultBaseURL,
            model: nonEmpty(env["ANTHROPIC_MODEL"]) ?? defaultModel
        )
    }

    func ask(question: String, history: [(question: String, answer: String)],
             onStatus: (@Sendable @MainActor (String) -> Void)? = nil) async throws -> String {
        let config = try Self.loadConfiguration()
        guard let endpoint = Self.endpointURL(baseURL: config.baseURL) else {
            throw DeepSeekError.badBaseURL
        }

        var messages: [[String: String]] = []
        for turn in history.suffix(Self.historyLimit) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])

        let body: [String: Any] = [
            "model": config.apiModel,
            "max_tokens": Self.maxTokens,
            "system": Self.systemPrompt,
            "messages": messages,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        await onStatus?("asking deepseek…")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekError.http(status: http.statusCode,
                                     message: Self.apiErrorMessage(from: data))
        }
        guard let text = Self.replyText(from: data) else { throw DeepSeekError.emptyReply }
        return text
    }

    private static func endpointURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/messages"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Joins every text block in `content`; nil when the reply has none.
    private static func replyText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String { return error }
        return json["message"] as? String
    }

    /// Reads `export NAME="value"` lines. Quotes are stripped; comments,
    /// blank lines and lines without `=` are ignored.
    private static func readEnvironment() -> [String: String] {
        guard let text = try? String(contentsOfFile: environmentURL.path, encoding: .utf8) else {
            return [:]
        }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            values[name] = value
        }
        return values
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum DeepSeekError: LocalizedError {
    case missingKey
    case badBaseURL
    case badResponse
    case http(status: Int, message: String?)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No DeepSeek API key found. Looked in Keychain (account \"deepseek\") and in ~/.config/claude-provider/deepseek.env for ANTHROPIC_AUTH_TOKEN."
        case .badBaseURL:
            return "The DeepSeek base URL is not valid. Check ANTHROPIC_BASE_URL in ~/.config/claude-provider/deepseek.env."
        case .badResponse:
            return "DeepSeek returned an unexpected response."
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "DeepSeek error (HTTP \(status)): \(message)"
            }
            return "DeepSeek error (HTTP \(status))."
        case .emptyReply:
            return "DeepSeek sent back an empty reply."
        }
    }
}
