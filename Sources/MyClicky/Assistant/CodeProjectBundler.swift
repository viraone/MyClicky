import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "code-project")

struct CodeProjectProfile: Sendable, Equatable {
    let title: String
    let instructions: String
    let relativePath: String
}

struct CodeStackItem: Sendable, Equatable {
    let name: String
    let evidence: String
}

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
    /// Maintainer-authored guidance, loaded separately so it is clearly
    /// instructions rather than project source.
    let profile: CodeProjectProfile?
    /// Technologies inferred from files and dependencies, with their evidence.
    let detectedStack: [CodeStackItem]
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

    /// Stable context that precedes the project source in the cached prompt.
    var guidanceText: String? {
        guard profile != nil || !detectedStack.isEmpty else { return nil }
        var sections: [String] = []
        if let profile {
            sections.append("""
            PROJECT PROFILE — maintainer-provided instructions from \(profile.relativePath):
            \(profile.instructions)
            """)
        }
        if !detectedStack.isEmpty {
            let lines = detectedStack.map { "- \($0.name): \($0.evidence)" }.joined(separator: "\n")
            sections.append("""
            DETECTED STACK — derived from the current project files:
            \(lines)
            """)
        }
        sections.append("""
        Treat the detected stack and project source as evidence of what exists today. \
        A profile may describe intended additions; never claim those are implemented \
        unless the project files confirm it. Ground recommendations in exact files.
        """)
        return sections.joined(separator: "\n\n")
    }

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
    static let maxProfileCharacters = 40_000
    static let profileRelativePath = ".peeky/project-profile.md"

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
        let profile = loadProfile(root: root, skippedFiles: &skippedFiles)
        let stack = detectStack(root: root, files: files)
        log.notice("bundled \(name, privacy: .public): \(files.count) files, \(total) chars, truncated=\(truncated)")
        return CodeProject(root: root, name: name, files: files, profile: profile, detectedStack: stack,
                           skippedFolders: Array(Set(skippedFolders)).sorted(),
                           skippedFiles: skippedFiles, truncated: truncated)
    }

    private static func loadProfile(root: URL, skippedFiles: inout [String]) -> CodeProjectProfile? {
        let url = root.appendingPathComponent(profileRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let text = decodeText(data) else {
            skippedFiles.append(profileRelativePath)
            return nil
        }
        let instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty, instructions.count <= maxProfileCharacters else {
            skippedFiles.append(profileRelativePath)
            return nil
        }
        let heading = instructions.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return CodeProjectProfile(title: heading?.isEmpty == false ? heading! : "Project Profile",
                                  instructions: instructions,
                                  relativePath: profileRelativePath)
    }

    private static func detectStack(root: URL, files: [CodeProject.File]) -> [CodeStackItem] {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path.lowercased(), $0.text) })
        let paths = Set(byPath.keys)
        var dependencies: [String: String] = [:]
        if let package = byPath["package.json"]?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: package) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                for (name, version) in json[key] as? [String: String] ?? [:] {
                    dependencies[name] = version
                }
            }
        }
        var result: [CodeStackItem] = []
        func add(_ name: String, _ evidence: String) {
            guard !result.contains(where: { $0.name == name }) else { return }
            result.append(CodeStackItem(name: name, evidence: evidence))
        }
        func dependency(_ name: String) -> String? {
            dependencies[name].map { "\(name) \($0) in package.json" }
        }

        if let evidence = dependency("typescript") {
            add("TypeScript", evidence)
        } else if paths.contains("tsconfig.json") || paths.contains(where: { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") }) {
            add("TypeScript", paths.contains("tsconfig.json") ? "tsconfig.json" : "TypeScript source files")
        }
        if let evidence = dependency("@playwright/test") { add("Playwright Test", evidence) }
        if paths.contains("package.json") {
            add("Node.js", dependency("@types/node") ?? "package.json")
        }
        let source = files.map(\.text).joined(separator: "\n")
        if source.contains("APIRequestContext") || source.contains("request.newContext(")
            || source.contains("request.get(") || source.contains("request.post(") {
            add("REST/API testing", "Playwright APIRequestContext usage")
        }
        if paths.contains(where: { $0.hasSuffix(".sql") }) { add("SQL", "SQL source files") }
        let workflows = root.appendingPathComponent(".github/workflows")
        if FileManager.default.fileExists(atPath: workflows.path) { add("GitHub Actions", ".github/workflows") }
        if paths.contains("dockerfile") || paths.contains(where: {
            $0 == "compose.yml" || $0 == "compose.yaml" || $0 == "docker-compose.yml" || $0 == "docker-compose.yaml"
        }) {
            add("Docker", paths.contains("dockerfile") ? "Dockerfile" : "Compose configuration")
        }
        if let eslint = dependency("eslint") { add("ESLint", eslint) }
        if let prettier = dependency("prettier") { add("Prettier", prettier) }
        if let config = byPath["playwright.config.ts"] ?? byPath["playwright.config.js"] {
            var reports: [String] = []
            if config.contains("'html'") || config.contains("\"html\"") { reports.append("HTML") }
            if config.contains("'junit'") || config.contains("\"junit\"") { reports.append("JUnit") }
            if !reports.isEmpty { add("\(reports.joined(separator: " + ")) reports", "playwright.config") }
        }
        if let allure = dependencies.first(where: { $0.key.lowercased().contains("allure") }) {
            add("Allure reporting", "\(allure.key) \(allure.value) in package.json")
        }
        return result
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
    /// `file` is the path Claude put after the language on the fence
    /// (```js app.js), when it did.
    case code(language: String, code: String, file: String?)

    static func code(language: String, code: String) -> CodeAnswerSegment { .code(language: language, code: code, file: nil) }

    static func parse(_ text: String) -> [CodeAnswerSegment] {
        var segments: [CodeAnswerSegment] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        var file: String?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }
        func close(_ open: [String]) {
            var lines = open
            // Some answers put the path on the block's first line instead of
            // the fence. It's a label, not code — lift it into the tag.
            if let first = lines.first?.trimmingCharacters(in: .whitespaces),
               lines.count > 1, looksLikePath(first) {
                if file == nil { file = first }
                lines.removeFirst()
            }
            segments.append(.code(language: language, code: lines.joined(separator: "\n"), file: file))
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    close(open)
                    code = nil
                } else {
                    flushProse()
                    let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    let words = info.split(separator: " ").map(String.init)
                    language = words.first ?? ""
                    // "```js app.js" or "```app.js" — anything with a dot or slash is a path.
                    file = words.dropFirst().first { $0.contains(".") || $0.contains("/") }
                    if file == nil, language.contains("."), language.contains("/") || language.split(separator: ".").count == 2 {
                        file = language; language = (language as NSString).pathExtension
                    }
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        if let open = code { close(open) }
        flushProse()
        return segments
    }

    /// `data/open-mics.json`, `App.swift`, `src/app.js:` — one token with an
    /// extension and nothing code-like in it.
    static func looksLikePath(_ s: String) -> Bool {
        var t = s
        if t.hasSuffix(":") { t.removeLast() }
        if t.hasPrefix("//") || t.hasPrefix("#") { t = t.drop { $0 == "/" || $0 == "#" || $0 == " " }.description }
        guard !t.isEmpty, !t.contains(" "), t.contains(".") else { return false }
        let ext = (t as NSString).pathExtension
        guard (1...6).contains(ext.count), ext.allSatisfy(\.isLetter) else { return false }
        return t.allSatisfy { $0.isLetter || $0.isNumber || "._-/".contains($0) }
    }
}

/// Putting a code block from an answer into a file.
/// A local, line-based LCS. Only trailing spaces/tabs are ignored, as in Apply.
enum LineDiff {
    struct Line: Equatable {
        enum Kind { case same, removed, added }
        let kind: Kind
        let text: String
    }

    static func diff(_ old: String, _ new: String) -> [Line] {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            if result.last == "" { result.removeLast() }
            return result
        }
        func normalized(_ line: String) -> String {
            var result = line
            while let last = result.last, last == " " || last == "\t" { result.removeLast() }
            return result
        }
        let before = lines(old), after = lines(new)
        let a = before.map(normalized), b = after.map(normalized)
        // Strip shared ends before allocating the table: whole-file cards usually
        // change only a small region, even when the live file is thousands of lines.
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in (0..<n).reversed() {
            for j in (0..<m).reversed() {
                lcs[i][j] = a[prefix + i] == b[prefix + j]
                    ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result = after.prefix(prefix).map { Line(kind: .same, text: $0) }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[prefix + i] == b[prefix + j] {
                result.append(Line(kind: .same, text: after[prefix + j])); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(Line(kind: .removed, text: before[prefix + i])); i += 1
            } else {
                result.append(Line(kind: .added, text: after[prefix + j])); j += 1
            }
        }
        result += after.suffix(suffix).map { Line(kind: .same, text: $0) }
        return result
    }

    static func summary(_ lines: [Line]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    enum Row: Equatable {
        case line(Line)
        case unchanged(Int)
    }

    /// Keep two context lines next to each change. A middle run of four
    /// lines stays intact because both changes need their two context lines.
    static func rows(_ lines: [Line]) -> [Row] {
        var result: [Row] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .same else {
                result.append(.line(lines[index])); index += 1; continue
            }
            let start = index
            while index < lines.count, lines[index].kind == .same { index += 1 }
            let count = index - start
            let leading = start > 0 ? min(2, count) : 0
            let trailing = index < lines.count ? min(2, count - leading) : 0
            if count > 3, count > leading + trailing {
                result += lines[start..<(start + leading)].map(Row.line)
                result.append(.unchanged(count - leading - trailing))
                result += lines[(index - trailing)..<index].map(Row.line)
            } else {
                result += lines[start..<index].map(Row.line)
            }
        }
        return result
    }
}

enum CodeBlockApplier {
    enum Outcome: Equatable {
        /// `find` was located and swapped for the block. `atLine` is the
        /// 1-based line the replacement starts on.
        case replaced(lines: Int, atLine: Int)
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
            let lineOf = { (t: String, i: String.Index) in t[..<i].reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
            if let range = text.range(of: needle) {
                return (text.replacingCharacters(in: range, with: block),
                        .replaced(lines: needle.components(separatedBy: "\n").count, atLine: lineOf(text, range.lowerBound)))
            }
            let looseText = normalized(text), looseNeedle = normalized(needle)
            if let range = looseText.range(of: looseNeedle) {
                return (looseText.replacingCharacters(in: range, with: block),
                        .replaced(lines: looseNeedle.components(separatedBy: "\n").count, atLine: lineOf(looseText, range.lowerBound)))
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

    /// True when `code` already appears in `text` (ignoring trailing
    /// whitespace) — i.e. it's a quote of the file, not a change to it.
    static func alreadyContains(_ code: String, in text: String) -> Bool {
        let block = normalized(trimmedNewlines(code))
        guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return normalized(text).contains(block)
    }
}


/// Works out, without asking Claude, which file an answer's code block is
/// about and the line it lands on — so the panel can offer "go there" and
/// apply the change even when that file isn't the one open.
enum CodeBlockLocator {
    struct Location: Equatable {
        let path: String
        /// 1-based first line of the code that will change (or of the best
        /// hint to it). nil when the file is known but the spot isn't.
        let line: Int?
        /// Lines the match spans, for highlighting.
        let lineCount: Int
    }

    /// `tagged` is the fence's file name; `find` the "current code" block
    /// before this one; `focused` the file open in the preview.
    /// `text(for:)` returns a file's current text (edits included).
    static func locate(code: String, find: String?, tagged: String?, focused: String?,
                       paths: [String], text: (String) -> String?) -> Location? {
        let candidates = candidateFiles(tagged: tagged, focused: focused, paths: paths)
        guard !candidates.isEmpty else { return nil }
        // 1. The exact "current code" — that's what Apply replaces.
        if let find, !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for path in candidates {
                if let t = text(path), let line = firstLine(of: find, in: t) {
                    return Location(path: path, line: line, lineCount: max(1, trimmed(find).components(separatedBy: "\n").count))
                }
            }
        }
        // 2. The block itself already lives in the file (a quote, or already applied).
        for path in candidates {
            if let t = text(path), let line = firstLine(of: code, in: t) {
                return Location(path: path, line: line, lineCount: max(1, trimmed(code).components(separatedBy: "\n").count))
            }
        }
        // 3. The thing the block defines — "function foo", "func bar", "let x".
        if let name = definedName(in: code) {
            for path in candidates {
                if let t = text(path), let line = firstLine(ofIdentifier: name, in: t) {
                    return Location(path: path, line: line, lineCount: 1)
                }
            }
        }
        // 4. A tagged file we know, just not where in it.
        if let tagged, let path = resolve(tagged, in: paths) { return Location(path: path, line: nil, lineCount: 0) }
        return nil
    }

    /// Where an identifier mentioned in prose is defined (or first used).
    static func locate(identifier: String, focused: String?, paths: [String], text: (String) -> String?) -> Location? {
        let name = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "`()"))
        guard name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$.]*$"#, options: .regularExpression) != nil, name.count >= 3 else { return nil }
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        var ordered = paths
        if let focused, let i = ordered.firstIndex(of: focused) { ordered.remove(at: i); ordered.insert(focused, at: 0) }
        // Prefer a definition anywhere over a mere use in the open file.
        for path in ordered {
            if let t = text(path), let line = definitionLine(of: leaf, in: t) { return Location(path: path, line: line, lineCount: 1) }
        }
        for path in ordered {
            if let t = text(path), let line = firstLine(ofIdentifier: leaf, in: t) { return Location(path: path, line: line, lineCount: 1) }
        }
        return nil
    }

    /// A project path matching a name Claude used: exact, or by suffix
    /// ("app.js" → "src/app.js"), or by file name alone.
    static func resolve(_ name: String, in paths: [String]) -> String? {
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"():,")).replacingOccurrences(of: "./", with: "")
        guard !clean.isEmpty else { return nil }
        if paths.contains(clean) { return clean }
        if let p = paths.first(where: { $0.hasSuffix("/" + clean) }) { return p }
        let leaf = (clean as NSString).lastPathComponent
        let byLeaf = paths.filter { ($0 as NSString).lastPathComponent == leaf }
        return byLeaf.count == 1 ? byLeaf.first : nil
    }

    private static func candidateFiles(tagged: String?, focused: String?, paths: [String]) -> [String] {
        var out: [String] = []
        if let tagged, let p = resolve(tagged, in: paths) { out.append(p) }
        if let focused, !out.contains(focused) { out.append(focused) }
        for p in paths where !out.contains(p) { out.append(p) }
        return out
    }

    private static func trimmed(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        while out.hasPrefix("\n") { out.removeFirst() }
        return out
    }

    private static func stripTrailing(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }.joined(separator: "\n")
    }

    /// 1-based line where `needle` (multi-line, trailing whitespace ignored) starts in `text`.
    static func firstLine(of needle: String, in text: String) -> Int? {
        let n = stripTrailing(trimmed(needle))
        guard !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hay = stripTrailing(text)
        guard let range = hay.range(of: n) else { return nil }
        return hay[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static func firstLine(ofIdentifier name: String, in text: String) -> Int? {
        let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_$])"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static let definers = "(?:function|func|class|struct|enum|protocol|interface|type|def|let|var|const|val|fn|static func|private func|public func|async function|export function|export const|export default function|@State private var|@Published var)"

    private static func definitionLine(of name: String, in text: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^[ \\t]*(?:export\\s+)?(?:(?:public|private|internal|static|final|override|async)\\s+)*" + definers + "\\s+" + escaped + "(?![A-Za-z0-9_$])"
        if let range = text.range(of: pattern, options: .regularExpression) {
            return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        // "foo: function(" / "foo = (" / "foo(" at line start — object methods and CSS-ish keys.
        let alt = "(?m)^[ \\t]*" + escaped + "\\s*(?:[:=]|\\()"
        if let range = text.range(of: alt, options: .regularExpression) {
            return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        return nil
    }

    /// The first identifier a block defines, if it opens with a definition.
    static func definedName(in code: String) -> String? {
        let pattern = "(?m)^[ \\t]*(?:export\\s+)?(?:(?:public|private|internal|static|final|override|async)\\s+)*" + definers + "\\s+([A-Za-z_$][A-Za-z0-9_$]*)"
        guard let match = code.range(of: pattern, options: .regularExpression) else { return nil }
        let line = String(code[match])
        return line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }).last.map(String.init)
    }
}
