import AppKit
import os

private let log = Logger(subsystem: "com.myclicky", category: "siteedit")

/// Editing the Mobile SDET study site (sdet-master-tracker) by voice.
///
/// The page puts a box into edit mode when the user clicks its pencil, and
/// records that in the URL as `#edit=<data-clicky-id>`. Clicky reads that
/// from the browser tab — the browser needn't be frontmost — asks Claude for
/// the rewrite, then lands the result in two places: the live DOM through
/// the page's `window.clickyEdit` API (so it appears on the other screen
/// immediately) and the HTML file on disk in the site's repo (the only copy
/// that persists). "Publish it" commits and pushes.
@MainActor
enum SiteEditActions {
    /// Where the site's working copy lives; the file edited is the one the
    /// tab's URL path ends in (`cs198-analogy.html`).
    nonisolated static let repoURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/SDET_MASTER")

    struct Context {
        let tabURL: String
        let boxID: String
        let file: URL
    }

    struct Box {
        let id: String
        let kind: String
        let label: String
        let html: String
        let text: String
    }

    /// True for the study site's pages, hosted or opened from disk (the main
    /// checkout or any worktree of it).
    static func isSite(_ url: String) -> Bool {
        url.contains("sdet-master-tracker") || url.contains("/SDET_MASTER/")
    }

    /// The box in edit mode in the site tab, if there is one. Nil when no
    /// browser shows the site or nothing is being edited.
    static func editContext() -> Context? {
        guard let tab = BrowserTabReader.activeTab(), isSite(tab.url) else { return nil }
        guard let hash = tab.url.range(of: "#edit="),
              case let id = String(tab.url[hash.upperBound...]).components(separatedBy: "&")[0],
              !id.isEmpty else { return nil }
        guard let file = fileURL(for: tab.url) else { return nil }
        return Context(tabURL: tab.url, boxID: id, file: file)
    }

    /// The site is open in a browser tab (whether or not a box is in edit mode).
    static func siteTabURL() -> String? {
        guard let tab = BrowserTabReader.activeTab(), isSite(tab.url) else { return nil }
        return tab.url
    }

    /// A page opened from disk is edited where it is (so a branch checked
    /// out in a worktree can be worked on before it's merged); the hosted
    /// site maps to the same-named file in the main checkout.
    private static func fileURL(for tabURL: String) -> URL? {
        guard let components = URLComponents(string: tabURL) else { return nil }
        if components.scheme == "file" {
            let file = URL(fileURLWithPath: components.path)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        var name = (components.path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { name = "index.html" }
        let file = repoURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The git working copy a file belongs to (the nearest ancestor with a
    /// `.git` entry — a worktree has a `.git` file rather than a directory).
    static func repo(containing file: URL) -> URL {
        var dir = file.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return repoURL
    }

    // MARK: - Page (live DOM)

    static func box(_ id: String) -> Box? {
        let js = "JSON.stringify(window.clickyEdit && window.clickyEdit.get(\(jsString(id))))"
        return parseBox(BrowserTabReader.runJavaScript(js, inTabMatching: isSite))
    }

    /// Short summaries of every box, for resolving "the one about TCP".
    static func listBoxes() -> [Box] {
        let js = "JSON.stringify(window.clickyEdit ? window.clickyEdit.list() : [])"
        guard let raw = BrowserTabReader.runJavaScript(js, inTabMatching: isSite),
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap(box(from:))
    }

    /// Puts `html` into the box on the page. False when the page's API isn't
    /// there (old page, JavaScript from Apple Events disabled) or the id is unknown.
    static func setBoxOnPage(_ id: String, html: String) -> Bool {
        let js = "String(!!(window.clickyEdit && window.clickyEdit.set(\(jsString(id)), \(jsString(html)))))"
        let result = BrowserTabReader.runJavaScript(js, inTabMatching: isSite)
        if result == nil { log.notice("page set: no JavaScript result — is 'Allow JavaScript from Apple Events' on?") }
        return result == "true"
    }

    static func finishEditOnPage() {
        _ = BrowserTabReader.runJavaScript("window.clickyEdit && window.clickyEdit.done()", inTabMatching: isSite)
    }

    private static func parseBox(_ raw: String?) -> Box? {
        guard let raw, raw != "null", let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return box(from: object)
    }

    private static func box(from object: [String: Any]) -> Box? {
        guard let id = object["id"] as? String else { return nil }
        return Box(id: id, kind: object["kind"] as? String ?? "insight", label: object["label"] as? String ?? "",
                   html: object["html"] as? String ?? "", text: object["text"] as? String ?? "")
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - File on disk

    enum FileWriteError: Error, LocalizedError {
        case boxNotFound(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .boxNotFound(let id): "Couldn't find box \(id) in the HTML file."
            case .malformed(let id): "Box \(id) in the HTML file isn't shaped the way I expected."
            }
        }
    }

    /// Replaces the editable content of box `id` in `file` with `html`. The
    /// page and the file share the `data-clicky-id` attribute, so the box is
    /// located by that, then its `<p>…</p>` (insight) or `<code>…</code>`
    /// (code panel) body is swapped. Nothing else in the file is touched.
    static func writeBoxToFile(_ id: String, html: String, in file: URL) throws {
        var source = try String(contentsOf: file, encoding: .utf8)
        guard let idRange = source.range(of: "data-clicky-id=\"\(id)\"") else { throw FileWriteError.boxNotFound(id) }
        // The element's opening tag started at the nearest '<' before the id.
        guard let tagStart = source[..<idRange.lowerBound].lastIndex(of: "<") else { throw FileWriteError.malformed(id) }
        let isCode = source[tagStart...].hasPrefix("<figure")
        let (open, close) = isCode ? ("<code>", "</code>") : ("<p>", "</p>")
        // The body ends at the last closing tag before this element ends.
        guard let bodyStart = source.range(of: open, range: idRange.upperBound..<source.endIndex),
              let elementEnd = source.range(of: isCode ? "</figure>" : "</div>", range: bodyStart.upperBound..<source.endIndex),
              let bodyEnd = source.range(of: close, options: .backwards, range: bodyStart.upperBound..<elementEnd.lowerBound)
        else { throw FileWriteError.malformed(id) }
        source.replaceSubrange(bodyStart.upperBound..<bodyEnd.lowerBound, with: html)
        try source.write(to: file, atomically: true, encoding: .utf8)
        log.notice("wrote \(html.count) chars into \(id, privacy: .public) in \(file.lastPathComponent, privacy: .public)")
    }

    // MARK: - Publish

    /// Commits every change in the site repo and pushes. Returns a sentence
    /// for the user.
    static func publish(repo: URL = repoURL, message: String = "Edit via Clicky") async -> (ok: Bool, message: String) {
        let steps: [[String]] = [
            ["git", "add", "-A"],
            ["git", "-c", "user.name=Clicky", "-c", "user.email=clicky@local", "commit", "-q", "-m", message],
            ["git", "push", "-q"],
        ]
        for step in steps {
            let (status, output) = await run(step, in: repo)
            if status != 0 {
                if step[step.count - 2] == "-m", output.contains("nothing to commit") {
                    return (true, "Nothing new to publish — the site already has everything.")
                }
                log.error("publish failed at \(step.joined(separator: " "), privacy: .public): \(output, privacy: .public)")
                return (false, "Publishing stopped at \(step[1]): \(output.split(separator: "\n").last.map(String.init) ?? "unknown error")")
            }
        }
        return (true, "Published — GitHub Pages will show it in about a minute.")
    }

    private static func run(_ arguments: [String], in directory: URL) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do { try process.run() } catch { continuation.resume(returning: (1, error.localizedDescription)) }
        }
    }
}
