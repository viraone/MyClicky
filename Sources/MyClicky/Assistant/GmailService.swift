import Foundation

/// Read-only Gmail client: builds a compact digest of the user's recent
/// inbox so Gemini can answer questions like "what's my latest email?" or
/// "summarize my unread emails".
struct GmailService {
    let auth: GoogleAuthService

    struct MessageSummary {
        let id: String
        let from: String
        let subject: String
        let date: String
        let snippet: String
        let unread: Bool
    }

    /// Returns a text digest of recent inbox messages, with the full body of
    /// the most recent one included.
    func inboxDigest(count: Int = 12) async throws -> String {
        let ids = try await recentMessageIDs(count: count)
        guard !ids.isEmpty else { return "The inbox has no recent messages." }

        var lines: [String] = []
        var summaries: [MessageSummary] = []
        for id in ids {
            if let summary = try? await messageSummary(id: id) {
                summaries.append(summary)
            }
        }
        for (index, s) in summaries.enumerated() {
            let marker = s.unread ? " [UNREAD]" : ""
            lines.append("\(index + 1). From: \(s.from)\(marker)\n   Subject: \(s.subject)\n   Date: \(s.date)\n   Preview: \(s.snippet)")
        }

        var digest = "Recent Gmail inbox messages (newest first):\n\n" + lines.joined(separator: "\n\n")
        if let first = summaries.first, let body = try? await messageBody(id: first.id) {
            let capped = body.count > 20_000 ? String(body.prefix(20_000)) + "\n…(truncated)" : body
            digest += "\n\nFull text of the most recent message (from \(first.from), subject “\(first.subject)”):\n\n\(capped)"
        }
        return digest
    }

    // MARK: - Thread actions

    struct ThreadInfo {
        let id: String
        let from: String
        let subject: String
    }

    /// Sender/subject of a thread (from its first message).
    func threadInfo(id: String) async throws -> ThreadInfo {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)")!
        components.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
        ]
        let json = try await getJSON(components.url!)
        let first = (json["messages"] as? [[String: Any]])?.first
        let headers = ((first?["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
        }
        return ThreadInfo(id: id, from: header("From"), subject: header("Subject"))
    }

    /// Finds the newest inbox thread whose subject matches (used when the
    /// browser URL doesn't expose the API thread ID).
    func findThread(subject: String) async throws -> String? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        let escaped = subject.replacingOccurrences(of: "\"", with: "")
        components.queryItems = [
            .init(name: "maxResults", value: "1"),
            .init(name: "q", value: "subject:\"\(escaped)\""),
        ]
        let json = try await getJSON(components.url!)
        return ((json["messages"] as? [[String: Any]]) ?? []).first?["threadId"] as? String
    }

    func trashThread(id: String) async throws {
        try await post(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)/trash")!)
    }

    func untrashThread(id: String) async throws {
        try await post(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)/untrash")!)
    }

    // MARK: - API calls

    /// Thread ID of the newest message in the Primary inbox (what Gmail shows
    /// at the top of the list).
    func latestInboxThreadID() async throws -> String? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            .init(name: "maxResults", value: "1"),
            .init(name: "labelIds", value: "INBOX"),
            .init(name: "q", value: "category:primary"),
        ]
        let json = try await getJSON(components.url!)
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.first?["threadId"] as? String
    }

    private func recentMessageIDs(count: Int) async throws -> [String] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            .init(name: "maxResults", value: String(count)),
            .init(name: "labelIds", value: "INBOX"),
        ]
        let json = try await getJSON(components.url!)
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.compactMap { $0["id"] as? String }
    }

    private func messageSummary(id: String) async throws -> MessageSummary {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        let json = try await getJSON(components.url!)
        let payload = json["payload"] as? [String: Any]
        let headers = payload?["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String ?? ""
        }
        let labels = json["labelIds"] as? [String] ?? []
        return MessageSummary(
            id: id,
            from: header("From"),
            subject: header("Subject"),
            date: header("Date"),
            snippet: (json["snippet"] as? String) ?? "",
            unread: labels.contains("UNREAD")
        )
    }

    private func messageBody(id: String) async throws -> String {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let json = try await getJSON(url)
        guard let payload = json["payload"] as? [String: Any] else { return "" }
        return Self.extractText(from: payload)
    }

    /// Walks MIME parts looking for text/plain (falling back to text/html).
    private static func extractText(from part: [String: Any]) -> String {
        let mimeType = part["mimeType"] as? String ?? ""
        if mimeType.hasPrefix("text/plain"), let text = decodedBody(part) {
            return text
        }
        if let parts = part["parts"] as? [[String: Any]] {
            for child in parts {
                let text = extractText(from: child)
                if !text.isEmpty { return text }
            }
        }
        if mimeType.hasPrefix("text/html"), let html = decodedBody(part) {
            // Crude tag strip so Gemini gets readable text.
            return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return ""
    }

    private static func decodedBody(_ part: [String: Any]) -> String? {
        guard let body = part["body"] as? [String: Any],
              let data = body["data"] as? String else { return nil }
        var base64 = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    private func post(_ url: URL) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            throw GmailError.api(message ?? "HTTP \(http.statusCode)")
        }
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
            throw GmailError.api(message ?? "HTTP \(http.statusCode)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    enum GmailError: LocalizedError {
        case badResponse
        case api(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: "Unexpected response from Gmail."
            case .api(let message): "Gmail error: \(message)"
            }
        }
    }
}
