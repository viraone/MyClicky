import Foundation

/// Google People API lookup, for turning a spoken first name into a real
/// email address before anything is drafted.
///
/// Searches both address books. "My contacts" holds people deliberately
/// saved; "other contacts" holds everyone merely corresponded with, which is
/// where most real recipients actually live.
@MainActor
struct ContactsService {
    let auth: GoogleAuthService

    struct Match: Hashable {
        let name: String
        let email: String
        var display: String { name.isEmpty ? email : "\(name) <\(email)>" }
    }

    /// Every contact whose name or address plausibly matches `query`, with
    /// duplicates across the two address books collapsed by email.
    func search(_ query: String) async throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let token = try await auth.validAccessToken()

        var seen: Set<String> = []
        var matches: [Match] = []
        for endpoint in ["people:searchContacts", "otherContacts:search"] {
            for person in try await search(trimmed, endpoint: endpoint, token: token) {
                let key = person.email.lowercased()
                if seen.insert(key).inserted { matches.append(person) }
            }
        }
        return matches
    }

    private func search(_ query: String, endpoint: String, token: String) async throws -> [Match] {
        var components = URLComponents(string: "https://people.googleapis.com/v1/\(endpoint)")!
        components.queryItems = [
            .init(name: "query", value: query),
            .init(name: "readMask", value: "names,emailAddresses"),
            .init(name: "pageSize", value: "20"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // The search index is built per-session: Google's first response after
        // a cold start is routinely empty even when matches exist, and the
        // documented fix is to warm it up and ask again. Without this retry a
        // real contact reads as "no match" on the first lookup of the day.
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ContactsError.badResponse }
            guard http.statusCode == 200 else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ContactsError.api(message)
                }
                throw ContactsError.api("HTTP \(http.statusCode)")
            }
            let results = Self.parse(data)
            if !results.isEmpty || attempt == 1 { return results }
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }
        return []
    }

    private static func parse(_ data: Data) -> [Match] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result -> Match? in
            guard let person = result["person"] as? [String: Any],
                  let emails = person["emailAddresses"] as? [[String: Any]],
                  let email = emails.first?["value"] as? String else { return nil }
            let name = (person["names"] as? [[String: Any]])?.first?["displayName"] as? String ?? ""
            return Match(name: name, email: email)
        }
    }

    enum ContactsError: LocalizedError {
        case badResponse
        case api(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: "Unexpected response from Google Contacts."
            case .api(let message): "Contacts error: \(message)"
            }
        }
    }
}
