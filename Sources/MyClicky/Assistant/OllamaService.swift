import Foundation

@MainActor
final class OllamaService {
    private static let baseURL = URL(string: "http://127.0.0.1:11434")!
    private var serverProcess: Process?

    func models() async throws -> [String] {
        try await ensureRunning()
        let (data, response) = try await URLSession.shared.data(from: Self.baseURL.appendingPathComponent("api/tags"))
        try Self.requireSuccess(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw OllamaError.badResponse
        }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    func ask(question: String, context: String?,
             history: [(question: String, answer: String)], model: String,
             onStatus: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await ensureRunning()
        try await ensureModel(model, onStatus: onStatus)

        let messages = Self.askMessages(question: question, context: context, history: history)
        let limit = await contextLength(of: model)
        guard let window = Self.contextWindow(for: messages, limit: limit) else {
            throw OllamaError.tooLarge(tokens: Self.estimatedTokens(of: messages), limit: limit)
        }
        onStatus?("\(model) · local text model")
        let body: [String: Any] = [
            "model": model,
            "keep_alive": Self.keepAlive,
            "stream": false,
            "messages": messages,
            "options": [
                "temperature": 0.3,
                "num_ctx": window,
                "num_predict": Self.askMaxOutputTokens,
            ],
        ]
        let data = try await post(path: "api/chat", body: body, timeout: 600)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw OllamaError.emptyResponse
        }
        return text
    }

    static func askMessages(question: String, context: String?,
                            history: [(question: String, answer: String)]) -> [[String: String]] {
        var messages: [[String: String]] = [[
            "role": "system",
            "content": """
            You are MyClicky, a helpful macOS assistant. Answer concisely and conversationally \
            in plain text. You are running locally and cannot see the user's screen or attached \
            images. Use any text context provided. If the question requires visual details that \
            are not present in the context, say that local mode cannot see the screen and suggest \
            switching Ask to Claude.
            """,
        ]]
        for turn in history.suffix(6) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        var current = ""
        if let context, !context.isEmpty {
            current += "Current app context:\n\n\(context)\n\n"
        }
        current += question
        messages.append(["role": "user", "content": current])
        return messages
    }

    func askAboutCode(question: String, project: CodeProject, focusedFile: String?,
                      changedFiles: [(path: String, text: String)],
                      history: [(question: String, answer: String)], model: String,
                      onStatus: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await ensureRunning()
        try await ensureModel(model, onStatus: onStatus)

        let messages = Self.messages(question: question, project: project, focusedFile: focusedFile,
                                     changedFiles: changedFiles, history: history)
        let limit = await contextLength(of: model)
        guard var window = Self.contextWindow(for: messages, limit: limit) else {
            throw OllamaError.tooLarge(tokens: Self.estimatedTokens(of: messages), limit: limit)
        }
        // Stay on the window the warm-up used: Ollama reloads the model and
        // drops the prompt cache whenever num_ctx changes.
        if let warm = warmWindows[Self.warmKey(model: model, system: messages[0]["content"] ?? "")], warm >= window {
            window = warm
        }
        let scope = focusedFile == nil ? "project slice" : "focused file"
        onStatus?("\(model) · \(scope) · \(window / 1024)K context")
        let body: [String: Any] = [
            "model": model,
            "keep_alive": Self.keepAlive,
            "stream": false,
            "messages": messages,
            "options": [
                "temperature": 0.2,
                "num_ctx": window,
                "num_predict": Self.codeMaxOutputTokens,
            ],
        ]
        let data = try await post(path: "api/chat", body: body, timeout: 600)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw OllamaError.emptyResponse
        }
        if let timing = Self.timingLine(json) { onStatus?("\(model) · \(timing)") }
        return text
    }

    /// Runs the project prompt through the model ahead of any question so
    /// its key/value cache is already resident. Ollama reuses the cached
    /// prefix for the next request with the same system message and
    /// num_ctx, so the question itself only has to process its own few
    /// tokens — measured at 35 s cold versus under a second warm for a
    /// 25K-token project. Returns the window it warmed, nil when the prompt
    /// doesn't fit the model.
    @discardableResult
    func warmCodePrompt(project: CodeProject, focusedFile: String?,
                        changedFiles: [(path: String, text: String)], model: String) async throws -> Int? {
        try await ensureRunning()
        try await ensureModel(model, onStatus: nil)
        let messages = Self.messages(question: "Ready.", project: project, focusedFile: focusedFile,
                                     changedFiles: changedFiles, history: [])
        let limit = await contextLength(of: model)
        // Leave room for a few turns of conversation so the real question
        // lands in this same window rather than the next bucket up.
        guard let window = Self.contextWindow(for: messages, limit: limit,
                                              headroom: Self.answerHeadroom + Self.conversationHeadroom) else {
            return nil
        }
        let key = Self.warmKey(model: model, system: messages[0]["content"] ?? "")
        let body: [String: Any] = [
            "model": model,
            "keep_alive": Self.keepAlive,
            "stream": false,
            "messages": messages,
            "options": ["temperature": 0.2, "num_ctx": window, "num_predict": 1],
        ]
        _ = try await post(path: "api/chat", body: body, timeout: 600)
        try Task.checkCancellation()
        warmWindows[key] = window
        return window
    }

    /// Windows warmed per model and system prompt, so a question reuses the
    /// exact num_ctx the cache was built with.
    private var warmWindows: [String: Int] = [:]
    private static func warmKey(model: String, system: String) -> String {
        "\(model)|\(system.count)|\(system.hashValue)"
    }

    /// "read 17K tokens in 0.1 s (cached) · wrote 312 tokens in 4.3 s".
    static func timingLine(_ json: [String: Any]) -> String? {
        guard let promptTokens = json["prompt_eval_count"] as? Int,
              let promptNanos = json["prompt_eval_duration"] as? Int,
              let outputTokens = json["eval_count"] as? Int,
              let outputNanos = json["eval_duration"] as? Int else { return nil }
        let promptSeconds = Double(promptNanos) / 1e9
        let outputSeconds = Double(outputNanos) / 1e9
        // A cache hit reads thousands of tokens in well under a second.
        let cached = promptTokens > 1_024 && promptSeconds < 1.5
        func tokens(_ n: Int) -> String { n >= 1_000 ? "\(n / 1_000)K tokens" : "\(n) tokens" }
        return "read \(tokens(promptTokens)) in \(String(format: "%.1f", promptSeconds)) s\(cached ? " (cached)" : "")"
            + " · wrote \(tokens(outputTokens)) in \(String(format: "%.1f", outputSeconds)) s"
    }

    /// One-shot structured request: a system prompt plus one user message,
    /// answered as a single JSON object. Ollama's JSON mode constrains the
    /// sampler to valid JSON, so local models can fill the same schemas
    /// Claude does (documentary scripts, paused-frame answers) without
    /// prose or code fences creeping in. `maxTokens` caps the answer and
    /// is also reserved in the context window so long outputs don't get
    /// truncated.
    func requestJSON(system: String, userText: String, model: String,
                     maxTokens: Int = 4_000, temperature: Double = 0.3, timeout: TimeInterval = 600,
                     onStatus: (@MainActor (String) -> Void)? = nil) async throws -> [String: Any] {
        try await ensureRunning()
        try await ensureModel(model, onStatus: onStatus)

        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": userText],
        ]
        let limit = await contextLength(of: model)
        guard let window = Self.contextWindow(for: messages, limit: limit,
                                              headroom: max(Self.answerHeadroom, maxTokens)) else {
            throw OllamaError.tooLarge(tokens: Self.estimatedTokens(of: messages), limit: limit)
        }
        onStatus?("\(model) · \(window / 1024)K context · JSON mode")
        let body: [String: Any] = [
            "model": model,
            "keep_alive": Self.keepAlive,
            "stream": false,
            "format": "json",
            "messages": messages,
            "options": ["temperature": temperature, "num_ctx": window, "num_predict": maxTokens],
        ]
        let data = try await post(path: "api/chat", body: body, timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw OllamaError.emptyResponse
        }
        guard let object = AnthropicService.parseJSONObject(from: text) else {
            throw OllamaError.notJSON
        }
        return object
    }

    /// The conversation as Ollama's chat API wants it: the same system
    /// prompt and project bundle Claude gets, plus a blunt restatement of
    /// the two-block edit format. Local models otherwise tend to answer
    /// with only the replacement, which leaves Apply nothing to match.
    ///
    /// Everything heavy — project slice, focused file, unsaved edits — sits
    /// in the system message, ahead of the conversation. Ollama caches the
    /// key/value state of the longest prefix it has seen, so keeping that
    /// text in a fixed position means the second question about a file
    /// costs a second, not the thirty the first one did.
    static func messages(question: String, project: CodeProject, focusedFile: String?,
                         changedFiles: [(path: String, text: String)],
                         history: [(question: String, answer: String)]) -> [[String: String]] {
        var messages: [[String: String]] = [[
            "role": "system",
            "content": systemPrompt(project: project, focusedFile: focusedFile, changedFiles: changedFiles),
        ]]
        for turn in history.suffix(localCodeHistoryLimit) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question + "\n\n" + questionReminder])
        return messages
    }

    static func systemPrompt(project: CodeProject, focusedFile: String?,
                             changedFiles: [(path: String, text: String)]) -> String {
        var system = AnthropicService.codeSystemPrompt
            + "\n\n" + editFormatReminder
            + (project.guidanceText.map { "\n\n\($0)" } ?? "")
            + "\n\n" + localProjectContext(project, focusedFile: focusedFile)
        let supplementalChangedFiles = changedFiles.filter { $0.path != focusedFile }
        if !supplementalChangedFiles.isEmpty {
            system += "\n\nSince the project snapshot was taken, these files changed. Use these current versions:\n\n"
            for file in supplementalChangedFiles {
                system += "===== FILE: \(file.path) (current) =====\n"
                    + excerpt(file.text, maxCharacters: maxLocalChangedFileCharacters)
                    + "\n\n"
            }
        }
        if let focusedFile {
            system += "\n\nThe user currently has \(focusedFile) open. Their question is about that file unless stated otherwise.\n\n"
            let text = changedFiles.first(where: { $0.path == focusedFile })?.text
                ?? project.files.first(where: { $0.path == focusedFile })?.text
            if let text {
                system += "Here is \(focusedFile) with line numbers. When the user refers to a line number, "
                    + "use these numbers exactly — do not count lines yourself:\n\n"
                    + numberedExcerpt(text, maxCharacters: maxLocalFocusedFileCharacters)
            }
        }
        return system
    }

    /// Local models pay the full prompt cost on every question and allocate
    /// a much larger KV cache as context grows. When a file is open, its
    /// numbered current contents already ride with the question, so sending
    /// the entire project as well only duplicates that file and can turn a
    /// small question into a 100K-token request. Keep the tree for navigation;
    /// without a focused file, include a bounded project slice.
    static func localProjectContext(_ project: CodeProject, focusedFile: String?) -> String {
        var out = "Project: \(project.name) — \(project.files.count) file\(project.files.count == 1 ? "" : "s")\n"
        out += "File tree:\n"
        for file in project.files { out += "  \(file.path)\n" }
        if focusedFile != nil {
            out += "\nThe focused file's current contents are supplied with the user's question. "
                + "Other files are listed by path only to keep this local request responsive."
            return out
        }

        out += "\nProject slice for local analysis:\n"
        var remaining = maxLocalProjectCharacters
        var included = 0
        for file in slicePriority(project.files) {
            let header = "===== FILE: \(file.path) =====\n"
            let needed = header.count + file.text.count + 2
            guard needed <= remaining else { continue }
            out += header + file.text
            if !file.text.hasSuffix("\n") { out += "\n" }
            out += "\n"
            remaining -= needed
            included += 1
        }
        if included < project.files.count {
            out += "(\(project.files.count - included) files omitted from the local slice; open one to ask about it directly.)\n"
        }
        return out
    }

    /// The slice is a budget, so spend it on what explains a project:
    /// READMEs and manifests first, then entry points, then everything
    /// else shallowest-first. Alphabetical order would spend it on
    /// whatever sorts before "src".
    static func slicePriority(_ files: [CodeProject.File]) -> [CodeProject.File] {
        func rank(_ path: String) -> Int {
            let name = (path as NSString).lastPathComponent.lowercased()
            let stem = (name as NSString).deletingPathExtension
            if name.hasPrefix("readme") { return 0 }
            if manifestNames.contains(name) { return 1 }
            if entryPointStems.contains(stem) { return 2 }
            if name.hasSuffix(".md") { return 3 }
            return 4
        }
        return files.enumerated().sorted { a, b in
            let ra = rank(a.element.path), rb = rank(b.element.path)
            if ra != rb { return ra < rb }
            let da = a.element.path.filter { $0 == "/" }.count, db = b.element.path.filter { $0 == "/" }.count
            if da != db { return da < db }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static let manifestNames: Set<String> = [
        "package.json", "package.swift", "pyproject.toml", "requirements.txt", "setup.py",
        "cargo.toml", "go.mod", "gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
        "composer.json", "mix.exs", "pubspec.yaml", "project.pbxproj", "makefile", "dockerfile",
        "docker-compose.yml", "tsconfig.json",
    ]
    private static let entryPointStems: Set<String> = [
        "main", "index", "app", "server", "cli", "daily", "__main__", "manage", "program",
    ]

    static let maxLocalProjectCharacters = 60_000
    static let maxLocalFocusedFileCharacters = 60_000
    static let maxLocalChangedFileCharacters = 30_000
    static let localCodeHistoryLimit = 3
    static let askMaxOutputTokens = 1_024
    static let codeMaxOutputTokens = 2_048
    /// Tokens a warm-up leaves free for the questions that follow it.
    static let conversationHeadroom = 4_096
    static let keepAlive = "30m"

    /// Appended to the system prompt for local models only.
    static let editFormatReminder = """
    Formatting rule that matters most here: when you change code that already exists, give TWO \
    fenced code blocks back to back. Block one is the current code copied exactly from the file, \
    unchanged, with enough lines to be unique. Block two is the replacement. Never give only the \
    replacement. Tag each fence with the file's real language and its path, for example \
    ```ts src/average.ts — ts for .ts files, swift for .swift files; never js for TypeScript.
    """

    /// Tacked onto the end of every question, where small models look last.
    static let questionReminder = "(Reminder: to change existing code, first a fenced block quoting the current code "
        + "exactly, then a second fenced block with the replacement. Tag both with language and file path.)"

    /// Context windows worth asking for, smallest first. Ollama reloads
    /// the model whenever `num_ctx` changes, so requests snap to one of
    /// these instead of tracking the prompt token by token.
    static let contextBuckets = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144]
    /// Room kept for the answer on top of the prompt.
    static let answerHeadroom = 4_096

    /// Rough token count of a conversation — code runs about 3.5
    /// characters a token, the same figure the project card uses.
    nonisolated static func estimatedTokens(of messages: [[String: String]]) -> Int {
        let characters = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        return Int(Double(characters) / 3.5)
    }

    /// The smallest bucket that holds the prompt plus headroom, capped at
    /// the model's own limit; nil when even the limit isn't enough (so the
    /// caller can say so rather than let Ollama silently drop the start of
    /// the prompt — which is the system prompt and the project). Left to
    /// its defaults Ollama sizes the key/value cache for the model's full
    /// window — 262K for Qwen3-Coder, about 26 GB on top of 17 GB of
    /// weights — on every question, however small the project.
    static func contextWindow(for messages: [[String: String]], limit: Int?,
                              headroom: Int? = nil) -> Int? {
        let needed = estimatedTokens(of: messages) + (headroom ?? answerHeadroom)
        if let limit, needed > limit { return nil }
        if let bucket = contextBuckets.first(where: { $0 >= needed }) {
            return limit.map { min(bucket, $0) } ?? bucket
        }
        return limit
    }

    private var contextLengths: [String: Int] = [:]

    /// The model's trained context length from `/api/show`, cached per
    /// model. nil when Ollama doesn't report one.
    func contextLength(of model: String) async -> Int? {
        if let known = contextLengths[model] { return known }
        guard let data = try? await post(path: "api/show", body: ["model": model], timeout: 30),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any],
              let entry = info.first(where: { $0.key.hasSuffix(".context_length") }),
              let length = entry.value as? Int else { return nil }
        contextLengths[model] = length
        return length
    }

    /// `"a\nb"` → `"1 | a\n2 | b"`, right-aligned so columns line up.
    static func numbered(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let width = String(lines.count).count
        return lines.enumerated().map { index, line in
            let number = String(index + 1)
            return String(repeating: " ", count: width - number.count) + number + " | " + line
        }.joined(separator: "\n")
    }

    /// Keeps the beginning and end of unusually large files while preserving
    /// their real line numbers. A bounded prompt makes local first-token
    /// latency predictable instead of jumping to a 64K or 128K KV cache.
    static func numberedExcerpt(_ text: String, maxCharacters: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        let width = String(lines.count).count
        let rendered = lines.enumerated().map { index, line in
            let number = String(index + 1)
            return String(repeating: " ", count: width - number.count) + number + " | " + line
        }
        let complete = rendered.joined(separator: "\n")
        guard complete.count > maxCharacters, rendered.count > 2 else { return complete }

        let halfBudget = max(1, (maxCharacters - 100) / 2)
        var head: [String] = []
        var headCount = 0
        for line in rendered {
            guard headCount + line.count + 1 <= halfBudget else { break }
            head.append(line)
            headCount += line.count + 1
        }

        var tail: [String] = []
        var tailCount = 0
        for line in rendered.reversed() {
            guard tailCount + line.count + 1 <= halfBudget else { break }
            tail.append(line)
            tailCount += line.count + 1
        }
        tail.reverse()

        let omitted = max(0, rendered.count - head.count - tail.count)
        return head.joined(separator: "\n")
            + "\n… \(omitted) lines omitted to keep local Qwen responsive …\n"
            + tail.joined(separator: "\n")
    }

    private static func excerpt(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let half = maxCharacters / 2
        let startEnd = text.index(text.startIndex, offsetBy: half)
        let endStart = text.index(text.endIndex, offsetBy: -half)
        return String(text[..<startEnd])
            + "\n… middle omitted to keep local Qwen responsive …\n"
            + String(text[endStart...])
    }

    private func ensureModel(_ model: String, onStatus: (@MainActor (String) -> Void)?) async throws {
        if try await models().contains(where: { $0 == model || $0.hasPrefix("\(model):") }) { return }
        onStatus?("Downloading \(model) to this Mac — this only happens once…")
        _ = try await post(path: "api/pull", body: ["name": model, "stream": false], timeout: 3_600)
        onStatus?("\(model) is ready locally.")
    }

    /// Ollama's default keeps up to three models resident, each for its
    /// keep-alive window — switch from Qwen to GPT-OSS to Llama 70B and all
    /// three sit in memory. When we start the server, one at a time; an
    /// explicit setting in the environment is respected.
    static func serverEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env["OLLAMA_MAX_LOADED_MODELS"] = base["OLLAMA_MAX_LOADED_MODELS"] ?? "1"
        return env
    }

    /// Models currently resident, per `/api/ps`. Empty when the server
    /// isn't running — this never starts it just to ask.
    func loadedModels() async -> [String] {
        guard await isRunning(),
              let (data, _) = try? await URLSession.shared.data(from: Self.baseURL.appendingPathComponent("api/ps")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Drops `model` from memory now instead of at the end of its keep-alive
    /// window. Only acts when it's actually resident (a `keep_alive: 0`
    /// request would otherwise load 17 GB just to unload it) and when the
    /// server was started outside the app with the default three-model
    /// limit. Returns whether anything was unloaded.
    @discardableResult
    func unload(_ model: String) async -> Bool {
        let loaded = await loadedModels()
        guard loaded.contains(where: { $0 == model || $0.hasPrefix("\(model):") }) else { return false }
        return (try? await post(path: "api/generate", body: ["model": model, "keep_alive": 0], timeout: 60)) != nil
    }

    private func ensureRunning() async throws {
        if await isRunning() { return }
        guard let executable = Self.ollamaExecutable() else { throw OllamaError.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.environment = Self.serverEnvironment(base: ProcessInfo.processInfo.environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw OllamaError.couldNotStart(error.localizedDescription)
        }
        serverProcess = process
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if await isRunning() { return }
            if !process.isRunning { break }
        }
        throw OllamaError.couldNotStart("The local service did not become ready.")
    }

    private func isRunning() async -> Bool {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func post(path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return data
    }

    private static func ollamaExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw OllamaError.api(json?["error"] as? String ?? "HTTP \(http.statusCode)")
        }
    }

    enum OllamaError: LocalizedError {
        case notInstalled
        case couldNotStart(String)
        case badResponse
        case emptyResponse
        case notJSON
        case api(String)
        case tooLarge(tokens: Int, limit: Int?)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let tokens, let limit):
                let cap = limit.map { " (\($0 / 1024)K tokens)" } ?? ""
                return "This project is about \(tokens / 1000)K tokens — more than the local model's context window\(cap). Drop a smaller folder, or switch to Claude."
            case .notInstalled: return "Ollama is not installed. Install it from ollama.com first."
            case .couldNotStart(let detail): return "Ollama could not start: \(detail)"
            case .badResponse: return "Ollama returned an unexpected response."
            case .emptyResponse: return "The local model returned an empty answer."
            case .notJSON: return "The local model's answer wasn't valid JSON. Try again, or switch to Claude."
            case .api(let message): return "Ollama error: \(message)"
            }
        }
    }
}
