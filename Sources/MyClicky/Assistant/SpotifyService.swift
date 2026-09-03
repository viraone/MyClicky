import AppKit
import CryptoKit
import Foundation
import Network

/// Spotify Web API for the things AppleScript can't do: searching the catalog
/// and editing playlists. Both work on Spotify Free. Auth is OAuth 2.0 PKCE
/// (no client secret) with a browser consent and a fixed loopback redirect,
/// which must be registered on the Spotify app as `redirectURI` below.
///
/// One-time setup:
///   security add-generic-password -s MyClicky -a spotify-client-id -w YOUR_CLIENT_ID
@MainActor
final class SpotifyService {
    static let redirectPort: UInt16 = 48211
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"
    static let scopeString = [
        "playlist-read-private",
        "playlist-modify-private",
        "playlist-modify-public",
    ].joined(separator: " ")

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    var onStatus: ((String) -> Void)?

    struct Track {
        let uri: String
        let name: String
        let artist: String
    }

    struct Playlist {
        let id: String
        let name: String
        let trackCount: Int
    }

    struct AddResult {
        var added: [Track] = []
        var missed: [String] = []
    }

    // MARK: - Public API

    /// Best match for a free-text query like "Daft Punk - Digital Love".
    func search(_ query: String) async throws -> Track? {
        let cleaned = Self.cleanQuery(query)
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            .init(name: "q", value: cleaned),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: "1"),
        ]
        let json = try await get(components.url!)
        guard let items = ((json["tracks"] as? [String: Any])?["items"] as? [[String: Any]]),
              let first = items.first,
              let uri = first["uri"] as? String,
              let name = first["name"] as? String else { return nil }
        let artist = ((first["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
        return Track(uri: uri, name: name, artist: artist)
    }

    /// The user's own playlists (most recent first, as Spotify orders them).
    func myPlaylists() async throws -> [Playlist] {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/playlists")!
        components.queryItems = [.init(name: "limit", value: "50")]
        let json = try await get(components.url!)
        return (json["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let count = ((item["tracks"] as? [String: Any])?["total"] as? Int) ?? 0
            return Playlist(id: id, name: name, trackCount: count)
        }
    }

    /// Finds a playlist by (case-insensitive) name.
    func playlist(named name: String) async throws -> Playlist? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await myPlaylists().first { $0.name.lowercased() == wanted }
    }

    func createPlaylist(named name: String, isPublic: Bool = false) async throws -> Playlist {
        let json = try await send("POST", URL(string: "https://api.spotify.com/v1/me/playlists")!,
                                  body: ["name": name, "public": isPublic])
        guard let id = json["id"] as? String else {
            throw APIError.unexpectedResponse("Playlist create returned no id")
        }
        return Playlist(id: id, name: name, trackCount: 0)
    }

    /// Searches each query and appends the matches to the playlist, in order.
    /// Queries with no match are reported back rather than failing the batch.
    func add(queries: [String], to playlist: Playlist,
             progress: ((Int, Int) -> Void)? = nil) async throws -> AddResult {
        var result = AddResult()
        for (index, query) in queries.enumerated() {
            progress?(index + 1, queries.count)
            if let track = try await search(query) {
                result.added.append(track)
            } else {
                result.missed.append(query)
            }
        }
        // Spotify accepts at most 100 URIs per call.
        for chunk in stride(from: 0, to: result.added.count, by: 100) {
            let uris = result.added[chunk..<min(chunk + 100, result.added.count)].map(\.uri)
            _ = try await send("POST", URL(string: "https://api.spotify.com/v1/playlists/\(playlist.id)/tracks")!,
                               body: ["uris": uris])
        }
        return result
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> [String: Any] {
        try await send("GET", url, body: nil)
    }

    private func send(_ method: String, _ url: URL, body: [String: Any]?) async throws -> [String: Any] {
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Strips YouTube-title noise ("(Official Audio)", "[Lyrics]", "ft.") so
    /// the search hits the right track.
    static func cleanQuery(_ raw: String) -> String {
        var s = raw
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"\|.*$"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)\b(official|audio|video|lyrics|hd|4k|visualizer|explicit|ft\.?|feat\.?)\b"#,
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " - ", with: " ")
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Auth

    func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let clientID = KeychainService.read(account: "spotify-client-id") else {
            throw APIError.missingClientID
        }
        if KeychainService.read(account: "spotify-scopes") != Self.scopeString {
            KeychainService.delete(account: "spotify-refresh-token")
        }
        if let refreshToken = KeychainService.read(account: "spotify-refresh-token") {
            do {
                return try await refresh(refreshToken: refreshToken, clientID: clientID)
            } catch {
                KeychainService.delete(account: "spotify-refresh-token")
            }
        }
        return try await authorize(clientID: clientID)
    }

    private func authorize(clientID: String) async throws -> String {
        onStatus?("Connecting to Spotify — check your browser…")

        let verifier = Self.randomURLSafeString(bytes: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let server = SpotifyLoopbackServer()
        try server.start(port: Self.redirectPort)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopeString),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        NSWorkspace.shared.open(components.url!)

        let code = try await server.waitForCode(timeout: 180)
        server.stop()

        let token = try await Self.tokenRequest(body: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
        store(token)
        return token.accessToken
    }

    private func refresh(refreshToken: String, clientID: String) async throws -> String {
        let token = try await Self.tokenRequest(body: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        store(token)
        return token.accessToken
    }

    private func store(_ token: TokenResponse) {
        // Spotify rotates refresh tokens on every refresh; always keep the newest.
        if let refreshToken = token.refreshToken {
            _ = KeychainService.save(account: "spotify-refresh-token", value: refreshToken)
            _ = KeychainService.save(account: "spotify-scopes", value: Self.scopeString)
        }
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private static func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .spotifyQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw APIError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return TokenResponse(accessToken: accessToken,
                             refreshToken: json["refresh_token"] as? String,
                             expiresIn: (json["expires_in"] as? TimeInterval) ?? 3600)
    }

    private static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum APIError: LocalizedError {
        case missingClientID
        case tokenExchangeFailed(String)
        case timedOut
        case denied
        case http(Int, String)
        case unexpectedResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                "Spotify Client ID not found in Keychain. Add it with:\nsecurity add-generic-password -s MyClicky -a spotify-client-id -w YOUR_CLIENT_ID"
            case .tokenExchangeFailed(let detail): "Spotify sign-in failed: \(detail)"
            case .timedOut: "Spotify sign-in timed out."
            case .denied: "Spotify sign-in was denied."
            case .http(let status, let body): "Spotify API error \(status): \(body)"
            case .unexpectedResponse(let detail): "Spotify API: \(detail)"
            }
        }
    }
}

/// One-shot HTTP listener on the fixed port Spotify has the redirect registered for.
private final class SpotifyLoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    func start(port: UInt16) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else { return }
                let code = Self.queryValue("code", fromRequestLine: request)
                let message = code != nil
                    ? "MyClicky is connected to Spotify. You can close this tab."
                    : "Sign-in failed or was cancelled. You can close this tab."
                let html = "<html><body style='font-family:sans-serif;padding:40px'><h2>\(message)</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self?.complete(code: code)
            }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SpotifyService.APIError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func complete(code: String?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let code {
            continuation?.resume(returning: code)
        } else {
            continuation?.resume(throwing: SpotifyService.APIError.denied)
        }
    }

    private static func queryValue(_ name: String, fromRequestLine request: String) -> String? {
        guard let line = request.components(separatedBy: "\r\n").first,
              let target = line.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)") else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}

private extension CharacterSet {
    static let spotifyQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?/:")
        return set
    }()
}
