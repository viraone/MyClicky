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

    /// One row of the cleanup inventory. Everything here comes from Drive's
    /// file metadata — no file content is read during the inventory pass.
    struct InventoryFile: Identifiable, Hashable {
        let id: String
        let name: String
        let mimeType: String
        /// Bytes of actual content. Google-native docs report no `size`, which
        /// is why `quotaBytes` exists alongside it.
        let size: Int64?
        /// Storage the file charges against the account — the only size signal
        /// a native Doc/Sheet/Slide gives, so it stands in for "is this empty".
        let quotaBytes: Int64?
        let createdTime: Date?
        let modifiedTime: Date?
        /// When *you* last opened it. Drive omits this for files never opened.
        let viewedByMeTime: Date?
        let webViewLink: String?

        /// What the file costs today, for the "reclaimable" total.
        var effectiveBytes: Int64 { size ?? quotaBytes ?? 0 }
        var isGoogleNative: Bool { mimeType.hasPrefix("application/vnd.google-apps") }
    }

    /// Every non-trashed file you own, one page at a time. Folders are left out
    /// deliberately: trashing a folder takes everything inside it with it, and
    /// this flow is meant to act on individual files only.
    ///
    /// `'me' in owners` keeps Shared-with-me and other people's files out of
    /// the result entirely, so nothing that isn't yours can reach the review
    /// screen — let alone the trash call.
    func inventory(progress: @escaping @MainActor (Int) -> Void) async throws -> [InventoryFile] {
        let token = try await auth.validAccessToken()
        let fields = "nextPageToken,files(id,name,mimeType,size,quotaBytesUsed," +
                     "createdTime,modifiedTime,viewedByMeTime,webViewLink)"
        let query = "'me' in owners and trashed = false and " +
                    "mimeType != 'application/vnd.google-apps.folder'"

        var files: [InventoryFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                .init(name: "q", value: query),
                .init(name: "fields", value: fields),
                .init(name: "pageSize", value: "1000"),
                .init(name: "spaces", value: "drive"),
                .init(name: "orderBy", value: "quotaBytesUsed desc"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response: response, data: data)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DriveError.badResponse
            }
            for raw in (json["files"] as? [[String: Any]] ?? []) {
                guard let id = raw["id"] as? String, let name = raw["name"] as? String else { continue }
                files.append(InventoryFile(
                    id: id,
                    name: name,
                    mimeType: raw["mimeType"] as? String ?? "",
                    size: (raw["size"] as? String).flatMap(Int64.init),
                    quotaBytes: (raw["quotaBytesUsed"] as? String).flatMap(Int64.init),
                    createdTime: Self.date(raw["createdTime"]),
                    modifiedTime: Self.date(raw["modifiedTime"]),
                    viewedByMeTime: Self.date(raw["viewedByMeTime"]),
                    webViewLink: raw["webViewLink"] as? String
                ))
            }
            let count = files.count
            await MainActor.run { progress(count) }
            pageToken = json["nextPageToken"] as? String
            try Task.checkCancellation()
        } while pageToken != nil

        return files
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        // Drive sends fractional seconds, but not on every field.
        return rfc3339.date(from: string) ?? ISO8601DateFormatter().date(from: string)
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
        return try await fileText(id: id, name: info.name, mimeType: info.mimeType, maxBytes: maxBytes)
    }

    /// Same, for callers that already know the name and type — a bulk pass
    /// holding inventory rows would otherwise pay a `fileInfo` round trip per
    /// file just to re-read metadata it already has.
    func fileText(id: String, name: String, mimeType: String,
                  maxBytes: Int = 60_000) async throws -> String? {
        let token = try await auth.validAccessToken()

        let url: URL?
        switch mimeType {
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
        return text.isEmpty ? nil : "Document: \(name)\n\n\(text)"
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
