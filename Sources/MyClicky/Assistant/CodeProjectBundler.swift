import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "code-project")

/// A folder (or handful of files) the user dropped on the Peeky Code tab,
/// read into memory as plain text so Claude can answer questions about it.
///
/// The whole project rides along with every question as one block of text.
/// That block is byte-identical from one question to the next, which is
/// exactly what Anthropic's prompt cache keys on: the first question pays
/// to read the project, follow-ups within the cache window are billed at
/// a tenth of that. Anything that changes the bytes (editing a file, then
/// reloading) is one full-price question and then cheap again.
struct CodeProject: Sendable, Equatable {
    struct File: Sendable, Equatable {
        /// Path relative to `root`, always with `/` separators.
        let path: String
        let text: String
    }

    let root: URL
    let name: String
    let files: [File]
    /// Folder names that were skipped wholesale (build output, assets…),
    /// deduplicated, for the "what did Peeky leave out" line.
    let skippedFolders: [String]
    /// Files passed over because they weren't text, were too big, or the
    /// project hit its size ceiling.
    let skippedFiles: [String]
    /// True when the size ceiling stopped the walk before every file was read.
    let truncated: Bool

    var totalCharacters: Int { files.reduce(0) { $0 + $1.text.count } }

    /// Rough token count. Code averages closer to 3.5 characters a token
    /// than prose's 4, and the answer is only ever shown as "≈".
    var estimatedTokens: Int { Int(Double(totalCharacters) / 3.5) }

    /// The text Claude sees: a file tree first (so it can reason about
    /// structure and ask for files by name), then every file under a header.
    var bundleText: String {
        var out = "Project: \(name) — \(files.count) file\(files.count == 1 ? "" : "s")\n"
        out += "File tree:\n"
        for file in files { out += "  \(file.path)\n" }
        if truncated {
            out += "  (…\(skippedFiles.count) more files omitted to fit the size limit)\n"
        }
        out += "\n"
        for file in files {
            out += "===== FILE: \(file.path) =====\n"
            out += file.text
            if !file.text.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        return out
    }

    /// One line for the project card: "23 files · ≈38K tokens".
    var summaryLine: String {
        "\(files.count) file\(files.count == 1 ? "" : "s") · ≈\(Self.compact(estimatedTokens)) tokens"
    }

    /// The files as a flat list grouped by their folder, root files first,
    /// then folders alphabetically — Finder's list view without the
    /// disclosure triangles.
    var filesByFolder: [(folder: String, files: [File])] {
        var groups: [String: [File]] = [:]
        for file in files {
            let folder = file.path.contains("/") ? String(file.path[..<file.path.lastIndex(of: "/")!]) : ""
            groups[folder, default: []].append(file)
        }
        return groups.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!) }
    }

    func file(at path: String) -> File? { files.first { $0.path == path } }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)K" }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

enum CodeProjectBundler {
    /// Ceiling on the text sent per question, in characters — about 170K
    /// tokens, leaving the rest of the 200K window for the conversation and
    /// the answer. Past this the walk stops and the project is marked truncated.
    static let maxTotalCharacters = 600_000
    /// A single file bigger than this is almost never source someone wrote
    /// (generated code, a data dump, a minified bundle) — skipped.
    static let maxFileBytes = 200_000
    static let maxFiles = 500

    /// Extensions that count as code or project text. Anything else is
    /// skipped so a dropped folder never drags in images, fonts, or binaries.
    static let sourceExtensions: Set<String> = [
        // Apple
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "metal", "plist", "entitlements", "strings", "xcconfig",
        // Web
        "html", "htm", "css", "scss", "sass", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
        // Everything else common
        "py", "java", "kt", "kts", "go", "rs", "rb", "php", "cs", "dart", "lua", "r", "scala", "sh", "bash", "zsh", "fish",
        "sql", "graphql", "proto",
        // Config and docs
        "json", "yaml", "yml", "toml", "xml", "ini", "cfg", "md", "markdown", "txt", "rst", "gradle", "csv",
    ]
    // Deliberately absent: .env, .pem, .key, .p12 — secrets must never be
    // bundled into a request.

    /// Extensionless files worth reading.
    static let sourceFileNames: Set<String> = [
        "Makefile", "Dockerfile", "Podfile", "Gemfile", "Procfile", "Rakefile", "Fastfile", "Brewfile", "LICENSE", "README",
    ]

    /// Lock files and the like: huge, machine-written, useless for questions.
    static let skippedFileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "Podfile.lock", "Gemfile.lock",
        "Cargo.lock", "poetry.lock", "composer.lock", ".DS_Store",
    ]

    /// Folders never descended into. Matched on the folder's own name.
    static let skippedFolderNames: Set<String> = [
        ".git", ".svn", ".hg", ".build", "build", "Build", "DerivedData", "node_modules", "Pods", "Carthage", ".swiftpm",
        "dist", "out", "target", ".venv", "venv", "env", "__pycache__", ".idea", ".vscode", ".gradle", "vendor",
        "coverage", ".next", ".nuxt", ".cache", "tmp",
    ]

    /// Folder *extensions* never descended into — Xcode's bundles, which are
    /// images and project-file plumbing rather than code.
    static let skippedFolderExtensions: Set<String> = [
        "xcassets", "xcodeproj", "xcworkspace", "playground", "framework", "app", "bundle", "lproj", "imageset", "appiconset", "colorset",
    ]

    /// Reads `urls` — one folder, several folders, or loose files — into a
    /// project. One folder becomes the project root; a mixed drop is rooted
    /// at the nearest folder that contains everything.
    static func bundle(urls: [URL]) -> CodeProject? {
        let urls = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !urls.isEmpty else { return nil }
        let root: URL
        let name: String
        if urls.count == 1, isDirectory(urls[0]) {
            root = urls[0]
            name = urls[0].lastPathComponent
        } else {
            root = commonParent(of: urls)
            name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items from \(root.lastPathComponent)"
        }

        var files: [CodeProject.File] = []
        var skippedFolders: [String] = []
        var skippedFiles: [String] = []
        var total = 0
        var truncated = false

        for url in urls.sorted(by: { $0.path < $1.path }) {
            if truncated { break }
            walk(url, root: root, files: &files, skippedFolders: &skippedFolders,
                 skippedFiles: &skippedFiles, total: &total, truncated: &truncated)
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        log.notice("bundled \(name, privacy: .public): \(files.count) files, \(total) chars, truncated=\(truncated)")
        return CodeProject(root: root, name: name, files: files,
                           skippedFolders: Array(Set(skippedFolders)).sorted(),
                           skippedFiles: skippedFiles, truncated: truncated)
    }

    private static func walk(_ url: URL, root: URL, files: inout [CodeProject.File],
                             skippedFolders: inout [String], skippedFiles: inout [String],
                             total: inout Int, truncated: inout Bool) {
        if isDirectory(url) {
            let name = url.lastPathComponent
            if url != root, shouldSkipFolder(url) {
                skippedFolders.append(name)
                return
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if truncated { return }
                walk(child, root: root, files: &files, skippedFolders: &skippedFolders,
                     skippedFiles: &skippedFiles, total: &total, truncated: &truncated)
            }
            return
        }

        let relative = relativePath(of: url, from: root)
        guard isSourceFile(url) else { return }
        if files.count >= maxFiles {
            truncated = true
            skippedFiles.append(relative)
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxFileBytes {
            skippedFiles.append(relative)
            return
        }
        guard let data = try? Data(contentsOf: url), let text = decodeText(data) else {
            skippedFiles.append(relative)
            return
        }
        if total + text.count > maxTotalCharacters {
            truncated = true
            skippedFiles.append(relative)
            return
        }
        total += text.count
        files.append(CodeProject.File(path: relative, text: text))
    }

    static func shouldSkipFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if skippedFolderNames.contains(name) { return true }
        if name.hasPrefix(".") { return true }
        return skippedFolderExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSourceFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if skippedFileNames.contains(name) { return false }
        if sourceFileNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return sourceExtensions.contains(ext)
    }

    /// UTF-8 text, or nil for anything binary. A NUL byte in the first few
    /// KB is the cheap tell for "this isn't text".
    static func decodeText(_ data: Data) -> String? {
        if data.prefix(8_000).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        let components = url.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func commonParent(of urls: [URL]) -> URL {
        var common = urls[0].deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().pathComponents
            var i = 0
            while i < min(common.count, parts.count), common[i] == parts[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common))
    }
}

/// An answer split into prose and fenced code blocks, so the blocks can be
/// shown as cards with Copy/Apply.
enum CodeAnswerSegment: Equatable {
    case prose(String)
    case code(language: String, code: String)

    static func parse(_ text: String) -> [CodeAnswerSegment] {
        var segments: [CodeAnswerSegment] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    segments.append(.code(language: language, code: open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        if let open = code { segments.append(.code(language: language, code: open.joined(separator: "\n"))) }
        flushProse()
        return segments
    }
}

/// Putting a code block from an answer into a file.
enum CodeBlockApplier {
    enum Outcome: Equatable {
        /// `find` was located and swapped for the block.
        case replaced(lines: Int)
        /// The block reads as the whole file and took its place.
        case rewroteFile
        /// Nowhere obvious to put it.
        case notFound
    }

    /// `find` is the block that preceded `code` in the answer — the code
    /// to replace, verbatim from the file. Matching ignores trailing
    /// whitespace on each line, which is where copy-through drifts.
    static func apply(_ code: String, replacing find: String?, in text: String) -> (String, Outcome) {
        let block = trimmedNewlines(code)
        if let find, !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = trimmedNewlines(find)
            if let range = text.range(of: needle) {
                return (text.replacingCharacters(in: range, with: block), .replaced(lines: needle.components(separatedBy: "\n").count))
            }
            let looseText = normalized(text), looseNeedle = normalized(needle)
            if let range = looseText.range(of: looseNeedle) {
                return (looseText.replacingCharacters(in: range, with: block), .replaced(lines: looseNeedle.components(separatedBy: "\n").count))
            }
        }
        // A whole-file rewrite: opens the way the file does and is about as long.
        let firstLine = { (s: String) in s.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "" }
        if !text.isEmpty, firstLine(block) == firstLine(text), Double(block.count) > Double(text.count) * 0.5 {
            return (block + "\n", .rewroteFile)
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (block + "\n", .rewroteFile)
        }
        return (text, .notFound)
    }

    private static func trimmedNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        while out.hasPrefix("\n") { out.removeFirst() }
        return out
    }

    private static func normalized(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }.joined(separator: "\n")
    }
}
