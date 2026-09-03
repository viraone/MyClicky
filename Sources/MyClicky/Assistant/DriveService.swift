import Foundation

/// Minimal Google Drive v3 client: file metadata + trash (recoverable 30 days).
@MainActor
struct DriveService {
    let auth: GoogleAuthService

    struct FileInfo {
        let id: String
        let name: String
        let mimeType: String
    }

    func fileInfo(id: String) async throws -> FileInfo {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,name,mimeType&supportsAllDrives=true")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response: response, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            throw DriveError.badResponse
        }
        return FileInfo(id: id, name: name, mimeType: json["mimeType"] as? String ?? "")
    }

    /// Moves the file to Drive's trash — recoverable for 30 days.
    func trash(id: String) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response: response, data: data)
    }

    /// Exports the full text of a Google Doc / Sheet / Presentation, or reads
    /// plain-text files directly. Returns nil for unsupported types.
    func fileText(id: String, maxBytes: Int = 60_000) async throws -> String? {
        let info = try await fileInfo(id: id)
        let token = try await auth.validAccessToken()

        let url: URL?
        switch info.mimeType {
        case "application/vnd.google-apps.document",
             "application/vnd.google-apps.presentation":
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=text/plain")
        case "application/vnd.google-apps.spreadsheet":
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=text/csv")
        case let mime where mime.hasPrefix("text/") || mime == "application/json":
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")
        default:
            url = nil
        }
        guard let url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response: response, data: data)
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.utf8.count > maxBytes {
            text = String(text.prefix(maxBytes)) + "\n…[truncated]"
        }
        return text.isEmpty ? nil : "Document: \(info.name)\n\n\(text)"
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw DriveError.api(message)
            }
            throw DriveError.api("HTTP \(http.statusCode)")
        }
    }

    enum DriveError: LocalizedError {
        case badResponse
        case api(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: "Unexpected response from Google Drive."
            case .api(let message): "Drive error: \(message)"
            }
        }
    }
}

/// Extracts a Drive file/document ID from a browser URL.
enum DriveURLParser {
    static func fileID(from urlString: String) -> String? {
        guard urlString.contains("google.com") else { return nil }
        let patterns = [
            #"/(?:file|document|spreadsheets|presentation)/d/([A-Za-z0-9_-]{10,})"#,
            #"/folders/([A-Za-z0-9_-]{10,})"#,
            #"[?&]id=([A-Za-z0-9_-]{10,})"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }
}
