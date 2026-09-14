import Foundation

/// The declarative contract of a Peeky extension: one `manifest.json` at the
/// root of the extension folder, plus whatever scripts it points at. Nothing
/// in an extension is compiled — languages, themes, formatters, linters and
/// actions are all data, and the scripts run in ordinary shells, so an
/// extension is a folder anyone can read, share, and fork.
///
/// Every `contributes` section is optional; a theme-only extension has one
/// entry, a "grab bag" can have all five.
struct ExtensionManifest: Codable, Equatable, Sendable {
    static let currentAPIVersion = 1
    static let fileName = "manifest.json"

    /// Reverse-DNS or slug; also the install folder name. `[A-Za-z0-9._-]` only.
    let id: String
    let name: String
    let version: String
    var description: String?
    var author: String?
    var homepage: String?
    /// The manifest schema this extension was written against. Peeky
    /// refuses newer ones rather than half-load them.
    var apiVersion: Int?
    var contributes: Contributes?

    struct Contributes: Codable, Equatable, Sendable {
        var languages: [Language]?
        var themes: [Theme]?
        var formatters: [Formatter]?
        var linters: [Linter]?
        var actions: [Action]?
    }

    // MARK: Language support

    /// A regex grammar for the Peeky Code preview. Either start from one of
    /// the built-in grammars (`base`) and add words, or give the full set.
    struct Language: Codable, Equatable, Sendable {
        let id: String
        var name: String?
        /// File extensions (no dot) this grammar claims. Extensions can
        /// override built-ins by listing their extension.
        let extensions: [String]
        /// One of: javascript, swift, python, css, html, json, shell, markdown.
        var base: String?
        var keywords: [String]?
        var control: [String]?
        /// e.g. "//" or "#"
        var lineComment: String?
        /// e.g. ["/*", "*/"]
        var blockComment: [String]?
        /// Extra raw regex rules, applied after the generated ones.
        var rules: [Rule]?

        struct Rule: Codable, Equatable, Sendable {
            let pattern: String
            /// One of the `SyntaxHighlighter.Token` names: plain, comment,
            /// string, number, keyword, control, function, type, variable,
            /// tag, attribute, selector, punctuation.
            let token: String
            var group: Int?
            var caseInsensitive: Bool?
        }
    }

    // MARK: Themes

    /// Colours for the Peeky Code preview. Keys are `SyntaxHighlighter.Token`
    /// names plus `background`; anything missing falls back to Dark Modern.
    struct Theme: Codable, Equatable, Sendable {
        let id: String
        let name: String
        /// token name → "#RRGGBB" or "#RRGGBBAA"
        let colors: [String: String]
    }

    // MARK: Formatters & linters

    /// A command that rewrites a file. With `stdin` true the current editor
    /// text is piped in and stdout becomes the new text; otherwise the file
    /// on disk is formatted in place and re-read.
    struct Formatter: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let extensions: [String]
        let command: String
        var args: [String]?
        var stdin: Bool?
        var timeout: Double?
    }

    /// A command whose output is turned into editor diagnostics. `pattern`
    /// is a regex with named groups `line`, `col` (optional), `severity`
    /// (optional; error/warning/info) and `message`, matched per line of
    /// stdout+stderr.
    struct Linter: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let extensions: [String]
        let command: String
        var args: [String]?
        var stdin: Bool?
        let pattern: String
        var timeout: Double?
    }

    // MARK: Actions

    /// A verb Peeky Actions (TALK / DO) can plan with, and the phone can
    /// fire directly with `EXT <verb>`. Claude sees `description`, `params`
    /// and `example`; when it picks the verb, `script` runs with the step's
    /// params as `PEEKY_PARAM_<NAME>` environment variables (and as JSON on
    /// stdin). Print a one-line result to stdout; a non-zero exit is failure
    /// and stderr becomes the reason shown.
    struct Action: Codable, Equatable, Sendable {
        let verb: String
        let description: String
        var params: [Param]?
        /// A complete JSON step, shown to the model verbatim.
        var example: String?
        /// Relative to the extension folder.
        let script: String
        /// shell (default), applescript, or javascript (JXA).
        var runner: String?
        var irreversible: Bool?
        /// Progress-tense status line, e.g. "Toggling dark mode…"
        var note: String?
        var timeout: Double?

        struct Param: Codable, Equatable, Sendable {
            let name: String
            var description: String?
            var required: Bool?
        }
    }
}

enum ExtensionRunner: String, Codable, Sendable, CaseIterable {
    case shell, applescript, javascript
}

enum ExtensionManifestError: LocalizedError, Equatable {
    case missingManifest
    case invalidJSON(String)
    case invalidID(String)
    case unsupportedAPIVersion(Int)
    case badVerb(String)
    case badRunner(String)
    case badRegex(String, String)
    case badColor(String, String)
    case duplicateVerb(String)
    case missingScript(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest: return "No manifest.json in the extension folder."
        case .invalidJSON(let detail): return "manifest.json isn't valid: \(detail)"
        case .invalidID(let id): return "Extension id “\(id)” may only use letters, digits, dots, dashes and underscores."
        case .unsupportedAPIVersion(let v): return "Needs Peeky extension API \(v); this build supports \(ExtensionManifest.currentAPIVersion)."
        case .badVerb(let verb): return "Action verb “\(verb)” must be lowercase letters, digits and underscores."
        case .badRunner(let r): return "Unknown runner “\(r)” — use shell, applescript or javascript."
        case .badRegex(let what, let detail): return "\(what) has an invalid regex: \(detail)"
        case .badColor(let key, let value): return "Theme colour \(key) = “\(value)” isn't #RRGGBB or #RRGGBBAA."
        case .duplicateVerb(let verb): return "Action verb “\(verb)” is declared twice."
        case .missingScript(let path): return "Script “\(path)” isn't in the extension folder."
        }
    }
}

extension ExtensionManifest {
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    static let verbPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{1,40}$")
    static let colorPattern = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")

    static func decode(_ data: Data) throws -> ExtensionManifest {
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            throw ExtensionManifestError.invalidJSON(Self.describe(error))
        }
        try manifest.validate()
        return manifest
    }

    /// Structural checks that don't need the folder: ids, verbs, regexes,
    /// colours. Script existence is checked at load time by the manager.
    func validate() throws {
        guard Self.idPattern.matches(id) else { throw ExtensionManifestError.invalidID(id) }
        if let apiVersion, apiVersion > Self.currentAPIVersion {
            throw ExtensionManifestError.unsupportedAPIVersion(apiVersion)
        }
        var verbs = Set<String>()
        for action in contributes?.actions ?? [] {
            guard Self.verbPattern.matches(action.verb) else { throw ExtensionManifestError.badVerb(action.verb) }
            guard verbs.insert(action.verb).inserted else { throw ExtensionManifestError.duplicateVerb(action.verb) }
            if let runner = action.runner, ExtensionRunner(rawValue: runner) == nil {
                throw ExtensionManifestError.badRunner(runner)
            }
        }
        for linter in contributes?.linters ?? [] {
            do { _ = try NSRegularExpression(pattern: linter.pattern, options: [.anchorsMatchLines]) }
            catch { throw ExtensionManifestError.badRegex("Linter \(linter.id)", error.localizedDescription) }
        }
        for language in contributes?.languages ?? [] {
            for rule in language.rules ?? [] {
                do { _ = try NSRegularExpression(pattern: rule.pattern, options: [.anchorsMatchLines]) }
                catch { throw ExtensionManifestError.badRegex("Language \(language.id) rule", error.localizedDescription) }
            }
        }
        for theme in contributes?.themes ?? [] {
            for (key, value) in theme.colors where !Self.colorPattern.matches(value) {
                throw ExtensionManifestError.badColor("\(theme.id).\(key)", value)
            }
        }
    }

    /// Paths of every script the manifest refers to, relative to its folder.
    var scriptPaths: [String] { (contributes?.actions ?? []).map(\.script) }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \(path(context))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let p = context.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "root" : p
    }
}

extension NSRegularExpression {
    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
