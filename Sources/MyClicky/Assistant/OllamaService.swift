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

        var messages: [[String: String]] = [[
            "role": "system",
            "content": AnthropicService.codeSystemPrompt
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
        current += question
        messages.append(["role": "user", "content": current])

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages,
            "options": ["temperature": 0.2],
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

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Ollama is not installed. Install it from ollama.com first."
            case .couldNotStart(let detail): return "Ollama could not start: \(detail)"
            case .badResponse: return "Ollama returned an unexpected response."
            case .emptyResponse: return "The local model returned an empty answer."
            case .api(let message): return "Ollama error: \(message)"
            }
        }
    }
}
