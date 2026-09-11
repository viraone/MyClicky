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

    func askAboutCode(question: String, project: CodeProject, focusedFile: String?,
                      changedFiles: [(path: String, text: String)],
                      history: [(question: String, answer: String)], model: String,
                      onStatus: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await ensureRunning()
        try await ensureModel(model, onStatus: onStatus)

        let messages = Self.messages(question: question, project: project, focusedFile: focusedFile,
                                     changedFiles: changedFiles, history: history)
        let limit = await contextLength(of: model)
        guard let window = Self.contextWindow(for: messages, limit: limit) else {
            throw OllamaError.tooLarge(tokens: Self.estimatedTokens(of: messages), limit: limit)
        }
        onStatus?("\(model) · \(window / 1024)K context")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages,
            "options": ["temperature": 0.2, "num_ctx": window],
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

    /// The conversation as Ollama's chat API wants it: the same system
    /// prompt and project bundle Claude gets, plus a blunt restatement of
    /// the two-block edit format. Local models otherwise tend to answer
    /// with only the replacement, which leaves Apply nothing to match.
    static func messages(question: String, project: CodeProject, focusedFile: String?,
                         changedFiles: [(path: String, text: String)],
                         history: [(question: String, answer: String)]) -> [[String: String]] {
        var messages: [[String: String]] = [[
            "role": "system",
            "content": AnthropicService.codeSystemPrompt
                + "\n\n" + editFormatReminder
                + (project.guidanceText.map { "\n\n\($0)" } ?? "")
                + "\n\n" + project.bundleText,
        ]]
        for turn in history.suffix(AnthropicService.codeHistoryLimit) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        var current = ""
        if !changedFiles.isEmpty {
            current += "Since the project snapshot was taken, these files changed. Use these current versions:\n\n"
            for file in changedFiles {
                current += "===== FILE: \(file.path) (current) =====\n\(file.text)\n\n"
            }
        }
        if let focusedFile {
            current += "The user currently has \(focusedFile) open. Their question is about that file unless stated otherwise.\n\n"
            let text = changedFiles.first(where: { $0.path == focusedFile })?.text
                ?? project.files.first(where: { $0.path == focusedFile })?.text
            if let text {
                current += "Here is \(focusedFile) with line numbers. When the user refers to a line number, "
                    + "use these numbers exactly — do not count lines yourself:\n\n"
                    + Self.numbered(text) + "\n\n"
            }
        }
        current += question + "\n\n" + questionReminder
        messages.append(["role": "user", "content": current])
        return messages
    }

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
    static func estimatedTokens(of messages: [[String: String]]) -> Int {
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
    static func contextWindow(for messages: [[String: String]], limit: Int?) -> Int? {
        let needed = estimatedTokens(of: messages) + answerHeadroom
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

    private func ensureModel(_ model: String, onStatus: (@MainActor (String) -> Void)?) async throws {
        if try await models().contains(where: { $0 == model || $0.hasPrefix("\(model):") }) { return }
        onStatus?("Downloading \(model) to this Mac — this only happens once…")
        _ = try await post(path: "api/pull", body: ["name": model, "stream": false], timeout: 3_600)
        onStatus?("\(model) is ready locally.")
    }

    private func ensureRunning() async throws {
        if await isRunning() { return }
        guard let executable = Self.ollamaExecutable() else { throw OllamaError.notInstalled }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
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
            case .api(let message): return "Ollama error: \(message)"
            }
        }
    }
}
