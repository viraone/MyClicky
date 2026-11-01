import Foundation

extension DeepSeekService {
    /// Sends one Anthropic-format Messages request that may use tools, and
    /// answers the raw content blocks plus the stop reason. The key and the
    /// endpoint come from the same place as `ask`, and nothing here logs or
    /// echoes the key.
    func sendRaw(system: String,
                 messages: [[String: Any]],
                 tools: [[String: Any]],
                 maxTokens: Int = 4_096) async throws -> (content: [[String: Any]], stopReason: String) {
        let config = try Self.loadConfiguration()
        guard let endpoint = Self.toolsEndpointURL(baseURL: config.baseURL) else {
            throw DeepSeekError.badBaseURL
        }

        var body: [String: Any] = [
            "model": config.apiModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekError.http(status: http.statusCode,
                                     message: Self.toolsErrorMessage(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw DeepSeekError.badResponse
        }
        let stopReason = json["stop_reason"] as? String ?? "end_turn"
        return (content: content, stopReason: stopReason)
    }

    /// The same endpoint rule as `ask`: the base URL from the environment
    /// file, with any trailing slashes removed, then `/v1/messages`.
    private static func toolsEndpointURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/messages"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Pulls the API's own error sentence out of a failed response, exactly
    /// like `ask`. The API key is never part of the answer.
    private static func toolsErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String { return error }
        return json["message"] as? String
    }
}

/// The real model behind the agent loop.
struct DeepSeekAgentClient: AgentModelClient {
    func send(system: String,
              messages: [[String: Any]],
              tools: [[String: Any]]) async throws -> (content: [[String: Any]], stopReason: String) {
        return try await DeepSeekService().sendRaw(system: system, messages: messages, tools: tools)
    }
}
