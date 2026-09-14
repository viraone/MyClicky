import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "extensions.marketplace")

/// One listing in the remote catalog. The catalog is a plain JSON file in a
/// GitHub repo (`viraone/peeky-extensions` by default), so publishing an
/// extension is a pull request that adds an entry pointing at its git URL.
///
/// ```json
/// { "catalogVersion": 1,
///   "extensions": [
///     { "id": "com.example.solarized", "name": "Solarized", "version": "1.0.0",
///       "description": "…", "author": "…", "repo": "https://github.com/…/….git",
///       "ref": "v1.0.0", "tags": ["theme"], "homepage": "https://…" } ] }
/// ```
struct MarketplaceEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    var description: String?
    var author: String?
    /// Git URL passed straight to `git clone`.
    let repo: String
    /// Optional tag/branch to clone.
    var ref: String?
    var tags: [String]?
    var homepage: String?

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = ([id, name, description ?? "", author ?? ""] + (tags ?? [])).joined(separator: " ").lowercased()
        return q.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

struct MarketplaceCatalog: Codable, Equatable, Sendable {
    var catalogVersion: Int?
    var extensions: [MarketplaceEntry]
}

@MainActor
final class ExtensionMarketplace: ObservableObject {
    static let defaultCatalogURL = "https://raw.githubusercontent.com/viraone/peeky-extensions/main/catalog.json"
    static let catalogURLKey = "extensionsCatalogURL"

    @Published private(set) var entries: [MarketplaceEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var fetchedAt: Date?
    @Published var query = ""

    /// Overridable so a fork or a private catalog can be used:
    /// `defaults write com.myclicky extensionsCatalogURL https://…/catalog.json`
    var catalogURL: URL {
        URL(string: UserDefaults.standard.string(forKey: Self.catalogURLKey) ?? Self.defaultCatalogURL)
            ?? URL(string: Self.defaultCatalogURL)!
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var filtered: [MarketplaceEntry] { entries.filter { $0.matches(query) } }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var request = URLRequest(url: catalogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Catalog returned HTTP \(http.statusCode)."])
            }
            let catalog = try Self.decode(data)
            entries = catalog.extensions
            fetchedAt = Date()
            log.notice("catalog: \(catalog.extensions.count) listing(s)")
        } catch {
            self.error = error.localizedDescription
            log.error("catalog fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func decode(_ data: Data) throws -> MarketplaceCatalog {
        let catalog = try JSONDecoder().decode(MarketplaceCatalog.self, from: data)
        if let v = catalog.catalogVersion, v > 1 {
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "Catalog version \(v) is newer than this Peeky understands."])
        }
        return catalog
    }

    /// Whether a newer version than what's installed is listed.
    static func isUpdate(_ entry: MarketplaceEntry, installed: LoadedExtension?) -> Bool {
        guard let installed = installed?.manifest else { return false }
        return compareVersions(entry.version, installed.version) == .orderedDescending
    }

    /// Dotted-numeric compare ("1.10.0" > "1.9.2"); non-numeric parts compare as strings.
    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map(String.init), pb = b.split(separator: ".").map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0", y = i < pb.count ? pb[i] : "0"
            if let nx = Int(x), let ny = Int(y) {
                if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending }
            } else if x != y {
                return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
