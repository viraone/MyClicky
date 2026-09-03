import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth 2.0 for a native desktop app: browser consent + loopback
/// redirect + PKCE. The refresh token is stored in the Keychain; access
/// tokens live in memory.
@MainActor
final class GoogleAuthService {
    static let driveScope = "https://www.googleapis.com/auth/drive"
    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
    /// All scopes MyClicky asks for. When this list changes, the stored
    /// refresh token is discarded so the user re-consents with the new scopes.
    static let scopeString = [driveScope, gmailScope].joined(separator: " ")

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    /// Message shown to the user while the browser consent flow is running.
    var onStatus: ((String) -> Void)?

    func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let clientID = KeychainService.read(account: "google-client-id"),
              let clientSecret = KeychainService.read(account: "google-client-secret") else {
            throw AuthError.missingClientCredentials
        }
        // If the app now needs more scopes than the stored token was granted,
        // force a fresh consent.
        if KeychainService.read(account: "google-scopes") != Self.scopeString {
            KeychainService.delete(account: "google-refresh-token")
        }
        if let refreshToken = KeychainService.read(account: "google-refresh-token") {
            do {
                return try await refresh(refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret)
            } catch {
                KeychainService.delete(account: "google-refresh-token")
            }
        }
        return try await authorize(clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: - Full consent flow

    private func authorize(clientID: String, clientSecret: String) async throws -> String {
        onStatus?("Authorizing with Google — check your browser…")

        let verifier = Self.randomURLSafeString(bytes: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let server = LoopbackServer()
        let port = try server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopeString),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)

        let code = try await server.waitForCode(timeout: 180)
        server.stop()

        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        let token = try await Self.tokenRequest(body: body)
        if let refreshToken = token.refreshToken {
            KeychainService.save(account: "google-refresh-token", value: refreshToken)
            KeychainService.save(account: "google-scopes", value: Self.scopeString)
        }
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
        return token.accessToken
    }

    private func refresh(refreshToken: String, clientID: String, clientSecret: String) async throws -> String {
        let body: [String: String] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let token = try await Self.tokenRequest(body: body)
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(token.expiresIn)
        return token.accessToken
    }

    // MARK: - Token endpoint

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    private static func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenExchangeFailed(detail)
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? TimeInterval) ?? 3600
        )
    }

    // MARK: - Helpers

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

    enum AuthError: LocalizedError {
        case missingClientCredentials
        case tokenExchangeFailed(String)
        case timedOut
        case denied

        var errorDescription: String? {
            switch self {
            case .missingClientCredentials:
                "Google OAuth credentials not found in Keychain. Add them with:\nsecurity add-generic-password -s MyClicky -a google-client-id -w\nsecurity add-generic-password -s MyClicky -a google-client-secret -w"
            case .tokenExchangeFailed(let detail):
                "Google token exchange failed: \(detail)"
            case .timedOut:
                "Google sign-in timed out."
            case .denied:
                "Google sign-in was denied."
            }
        }
    }
}

/// Tiny one-shot HTTP listener for the OAuth loopback redirect.
private final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else { return }
                let code = Self.queryValue("code", fromRequestLine: request)
                let message = code != nil
                    ? "MyClicky is connected to Google. You can close this tab."
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
        // Wait briefly for the port to be assigned.
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port > 0 { return port }
            usleep(20_000)
        }
        throw GoogleAuthService.AuthError.tokenExchangeFailed("Could not open loopback port.")
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
                throw GoogleAuthService.AuthError.timedOut
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
            continuation?.resume(throwing: GoogleAuthService.AuthError.denied)
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
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?/:")
        return set
    }()
}
