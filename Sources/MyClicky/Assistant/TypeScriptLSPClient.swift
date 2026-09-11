import Foundation

enum CodeLSPStatus: Equatable {
    case inactive
    case starting(String)
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .inactive: return "LSP off"
        case .starting(let detail): return detail
        case .ready: return "TypeScript LSP"
        case .failed: return "LSP unavailable"
        }
    }

    var detail: String {
        switch self {
        case .inactive: return "No TypeScript project is active."
        case .starting(let detail): return detail
        case .ready: return "Diagnostics, hover information, and go to definition are active."
        case .failed(let detail): return detail
        }
    }
}

struct CodeLSPPosition: Equatable {
    let line: Int
    let character: Int
}

struct CodeLSPRange: Equatable {
    let start: CodeLSPPosition
    let end: CodeLSPPosition
}

struct CodeLSPDiagnostic: Equatable, Identifiable {
    let range: CodeLSPRange
    let severity: Int
    let message: String
    let source: String?

    var id: String {
        "\(range.start.line):\(range.start.character):\(range.end.line):\(range.end.character):\(severity):\(message)"
    }
}

struct CodeLSPLocation: Equatable {
    let path: String
    let range: CodeLSPRange
}

struct LSPMessageFramer {
    private(set) var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)

    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let headerEnd = buffer.range(of: Self.separator) {
            let headerData = buffer[..<headerEnd.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8),
                  let lengthLine = header.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces))
            else {
                buffer.removeSubrange(..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.count - bodyStart >= length else { break }
            let bodyEnd = bodyStart + length
            let body = buffer[bodyStart..<bodyEnd]
            buffer.removeSubrange(..<bodyEnd)
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                messages.append(object)
            }
        }
        return messages
    }
}

@MainActor
final class TypeScriptLSPClient {
    var onStatus: ((CodeLSPStatus) -> Void)?
    var onDiagnostics: ((String, [CodeLSPDiagnostic]) -> Void)?
    var onHover: ((String?) -> Void)?
    var onDefinition: ((CodeLSPLocation?) -> Void)?

    private struct Document {
        var text: String
        var version: Int
        var opened = false
    }

    private struct Launcher {
        let executable: URL
        let arguments: [String]
        let downloadsServer: Bool
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var framer = LSPMessageFramer()
    private var root: URL?
    private var documents: [URL: Document] = [:]
    private var pending: [Int: (Any?) -> Void] = [:]
    private var nextID = 1
    private var generation = 0
    private var ready = false
    private var stderr = ""

    func start(for project: CodeProject) {
        stop()
        guard project.detectedStack.contains(where: { $0.name == "TypeScript" }) else {
            onStatus?(.inactive)
            return
        }
        root = project.root.standardizedFileURL.resolvingSymlinksInPath()
        let launcher = launcher(for: project.root)
        onStatus?(.starting(launcher.downloadsServer ? "Starting TypeScript LSP…" : "Starting local TypeScript LSP…"))

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let errors = Pipe()
        process.executableURL = launcher.executable
        process.arguments = launcher.arguments
        process.currentDirectoryURL = project.root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existingPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (standardPaths + existingPaths.filter { !standardPaths.contains($0) })
            .joined(separator: ":")
        process.environment = environment

        generation += 1
        let activeGeneration = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.receive(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.stderr += String(decoding: data, as: UTF8.self)
                if self.stderr.count > 4_000 { self.stderr = String(self.stderr.suffix(4_000)) }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.ready = false
                let detail = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.onStatus?(.failed(detail.isEmpty
                    ? "TypeScript language server exited (\(process.terminationStatus))."
                    : String(detail.suffix(300))))
            }
        }

        do {
            try process.run()
        } catch {
            onStatus?(.failed(error.localizedDescription))
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = errors.fileHandleForReading
        initialize()
    }

    func stop() {
        generation += 1
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        root = nil
        documents = [:]
        pending = [:]
        framer = LSPMessageFramer()
        ready = false
        stderr = ""
        onStatus?(.inactive)
    }

    func focus(path: String, text: String) {
        guard Self.supports(path: path) else { return }
        guard let url = fileURL(for: path) else { return }
        var document = documents[url] ?? Document(text: text, version: 1)
        document.text = text
        documents[url] = document
        if ready { openIfNeeded(url) }
    }

    func change(path: String, text: String) {
        guard Self.supports(path: path) else { return }
        guard let url = fileURL(for: path) else { return }
        var document = documents[url] ?? Document(text: text, version: 0)
        document.text = text
        document.version += 1
        documents[url] = document
        guard ready else { return }
        openIfNeeded(url)
        notify("textDocument/didChange", [
            "textDocument": ["uri": url.absoluteString, "version": document.version],
            "contentChanges": [["text": text]],
        ])
    }

    func hover(path: String, characterOffset: Int, text: String) {
        guard ready, Self.supports(path: path), let url = fileURL(for: path) else { onHover?(nil); return }
        focus(path: path, text: text)
        let position = Self.position(in: text, utf16Offset: characterOffset)
        request("textDocument/hover", params: textDocumentPosition(url, position)) { [weak self] result in
            self?.onHover?(Self.hoverText(from: result))
        }
    }

    func definition(path: String, characterOffset: Int, text: String) {
        guard ready, Self.supports(path: path), let url = fileURL(for: path) else { onDefinition?(nil); return }
        focus(path: path, text: text)
        let position = Self.position(in: text, utf16Offset: characterOffset)
        request("textDocument/definition", params: textDocumentPosition(url, position)) { [weak self] result in
            self?.onDefinition?(self?.location(from: result, source: url))
        }
    }

    private func launcher(for root: URL) -> Launcher {
        let local = root.appendingPathComponent("node_modules/.bin/typescript-language-server")
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return Launcher(executable: local, arguments: ["--stdio"], downloadsServer: false)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("typescript-language-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return Launcher(executable: candidate, arguments: ["--stdio"], downloadsServer: false)
            }
        }
        return Launcher(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npm", "exec", "--yes", "--package=typescript-language-server@4",
                        "--package=typescript@5", "--",
                        "typescript-language-server", "--stdio"],
            downloadsServer: true
        )
    }

    private func initialize() {
        guard let root else { return }
        request("initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "capabilities": [
                "textDocument": [
                    "publishDiagnostics": ["relatedInformation": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": ["linkSupport": true],
                ],
            ],
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
        ]) { [weak self] result in
            guard let self else { return }
            guard result != nil else {
                self.onStatus?(.failed("The TypeScript language server rejected initialization."))
                return
            }
            self.notify("initialized", [:])
            self.ready = true
            for url in self.documents.keys.sorted(by: { $0.path < $1.path }) {
                self.openIfNeeded(url)
            }
            self.onStatus?(.ready)
        }
    }

    private func openIfNeeded(_ url: URL) {
        guard var document = documents[url], !document.opened else { return }
        document.opened = true
        documents[url] = document
        notify("textDocument/didOpen", [
            "textDocument": [
                "uri": url.absoluteString,
                "languageId": Self.languageID(for: url),
                "version": document.version,
                "text": document.text,
            ],
        ])
    }

    private func fileURL(for path: String) -> URL? {
        guard let root else { return nil }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    private func textDocumentPosition(_ url: URL, _ position: CodeLSPPosition) -> [String: Any] {
        [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ]
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Any?) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var packet = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
        packet.append(data)
        do {
            try input.write(contentsOf: packet)
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    private func receive(_ data: Data) {
        for message in framer.append(data) {
            if let id = (message["id"] as? NSNumber)?.intValue, let completion = pending.removeValue(forKey: id) {
                completion(message["result"])
                continue
            }
            if let id = (message["id"] as? NSNumber)?.intValue,
               let method = message["method"] as? String {
                respond(to: id, method: method, params: message["params"])
                continue
            }
            guard message["method"] as? String == "textDocument/publishDiagnostics",
                  let params = message["params"] as? [String: Any],
                  let uri = params["uri"] as? String,
                  let url = URL(string: uri),
                  let path = relativePath(for: url),
                  let raw = params["diagnostics"] as? [[String: Any]]
            else { continue }
            onDiagnostics?(path, raw.compactMap(Self.diagnostic(from:)))
        }
    }

    private func respond(to id: Int, method: String, params: Any?) {
        switch method {
        case "workspace/configuration":
            let count = ((params as? [String: Any])?["items"] as? [Any])?.count ?? 0
            send(["jsonrpc": "2.0", "id": id, "result": Array(repeating: [String: Any](), count: count)])
        case "workspace/workspaceFolders":
            if let root {
                send(["jsonrpc": "2.0", "id": id,
                      "result": [["uri": root.absoluteString, "name": root.lastPathComponent]]])
            } else {
                send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
        }
    }

    private func relativePath(for url: URL) -> String? {
        guard let root else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count))
    }

    private func location(from result: Any?, source: URL) -> CodeLSPLocation? {
        let values = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        let locations = values.compactMap { value -> (URL, CodeLSPLocation)? in
            guard let uri = (value["targetUri"] ?? value["uri"]) as? String,
              let url = URL(string: uri),
              let path = relativePath(for: url),
              let range = Self.range(from: value["targetSelectionRange"] ?? value["range"])
            else { return nil }
            return (url.standardizedFileURL, CodeLSPLocation(path: path, range: range))
        }
        return locations.first(where: { $0.0 != source.standardizedFileURL })?.1 ?? locations.first?.1
    }

    nonisolated static func position(in text: String, utf16Offset: Int) -> CodeLSPPosition {
        let units = Array(text.utf16)
        let end = min(max(0, utf16Offset), units.count)
        var line = 0
        var lineStart = 0
        for index in 0..<end where units[index] == 10 {
            line += 1
            lineStart = index + 1
        }
        return CodeLSPPosition(line: line, character: end - lineStart)
    }

    nonisolated static func nsRange(_ range: CodeLSPRange, in text: String) -> NSRange? {
        let starts = [0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
        guard range.start.line >= 0, range.start.line < starts.count,
              range.end.line >= 0, range.end.line < starts.count else { return nil }
        let start = starts[range.start.line] + range.start.character
        let end = starts[range.end.line] + range.end.character
        guard start >= 0, end >= start, end <= text.utf16.count else { return nil }
        return NSRange(location: start, length: end - start)
    }

    nonisolated static func supports(path: String) -> Bool {
        ["ts", "tsx", "js", "jsx", "mjs", "cjs"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func languageID(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "tsx": return "typescriptreact"
        case "jsx": return "javascriptreact"
        case "js", "mjs", "cjs": return "javascript"
        default: return "typescript"
        }
    }

    private static func diagnostic(from value: [String: Any]) -> CodeLSPDiagnostic? {
        guard let range = range(from: value["range"]), let message = value["message"] as? String else { return nil }
        return CodeLSPDiagnostic(range: range,
                                 severity: (value["severity"] as? NSNumber)?.intValue ?? 3,
                                 message: message,
                                 source: value["source"] as? String)
    }

    private static func range(from value: Any?) -> CodeLSPRange? {
        guard let value = value as? [String: Any],
              let start = position(from: value["start"]),
              let end = position(from: value["end"]) else { return nil }
        return CodeLSPRange(start: start, end: end)
    }

    private static func position(from value: Any?) -> CodeLSPPosition? {
        guard let value = value as? [String: Any],
              let line = (value["line"] as? NSNumber)?.intValue,
              let character = (value["character"] as? NSNumber)?.intValue else { return nil }
        return CodeLSPPosition(line: line, character: character)
    }

    private static func hoverText(from result: Any?) -> String? {
        guard let result = result as? [String: Any] else { return nil }
        return markupText(result["contents"])
    }

    private static func markupText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let dictionary = value as? [String: Any] {
            return dictionary["value"] as? String ?? dictionary["language"] as? String
        }
        if let array = value as? [Any] {
            let parts = array.compactMap(markupText)
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }
}
