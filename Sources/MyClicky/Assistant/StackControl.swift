import Foundation

/// The local coding stack: `~/.claude/skills/stack/stack.sh` starts or stops
/// Qwen and the project's own servers, and reports who Qwen works for.
enum StackControl {
    struct State {
        enum Power: String { case on = "ON", off = "OFF", busy = "BUSY" }
        var power: Power
        var ok: Bool
        var project: String
        var message: String
        var line: String { "STACK_STATE \(power.rawValue) \(ok ? "OK" : "FAIL")\t\(project)\t\(message)" }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let script = home.appendingPathComponent(".claude/skills/stack/stack.sh")

    /// The folder of the chat Claude Code is being used in: the newest
    /// transcript under ~/.claude/projects, and the last "cwd" it holds.
    static func activeChatFolder() -> URL? {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: []) else { return nil }
        var newest: URL?
        var newestDate = Date.distantPast
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: []) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date > newestDate else { continue }
                newestDate = date
                newest = file
            }
        }
        guard let newest else { return nil }
        return folder(in: newest)
    }

    static func status() async -> State {
        let (stdout, error) = await output("status", in: home, timeout: 30)
        guard let stdout else { return State(power: .off, ok: false, project: "", message: error ?? "stack.sh failed") }
        return parsed(stdout)
    }

    static func turnOn() async -> State {
        let (stdout, error) = await output("on", in: activeChatFolder() ?? home, timeout: 300)
        guard let stdout else { return State(power: .off, ok: false, project: "", message: error ?? "stack.sh failed") }
        if let stopped = stopped(stdout) {
            let now = await status()
            return State(power: now.power, ok: false, project: now.project, message: stopped)
        }
        var state = parsed(stdout)
        let loading = qwenLine(stdout)?.contains("not answering yet") ?? false
        let who = state.project.isEmpty ? "Stack ON" : "Stack ON for \(state.project)"
        state.message = "\(who) — Qwen \(loading ? "loading" : "ready")"
        return state
    }

    static func turnOff() async -> State {
        let (stdout, error) = await output("off", in: home, timeout: 120)
        guard let stdout else { return State(power: .off, ok: false, project: "", message: error ?? "stack.sh failed") }
        if let stopped = stopped(stdout) {
            let now = await status()
            return State(power: now.power, ok: false, project: now.project, message: stopped)
        }
        var state = parsed(stdout)
        state.message = "Stack OFF — everything stopped"
        return state
    }

    private static func output(_ action: String, in folder: URL, timeout: TimeInterval) async -> (stdout: String?, error: String?) {
        guard FileManager.default.fileExists(atPath: script.path) else { return (nil, "stack.sh not found") }
        var environment = ["STACK_START_DEV": "1",
                           "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            environment["PATH"]! += ":" + inherited
        }
        do {
            let result = try await ExtensionScriptRunner.run(ExtensionScriptRunner.Invocation(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, action],
                currentDirectory: folder,
                environment: environment,
                timeout: timeout))
            return (result.stdout, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func parsed(_ stdout: String) -> State {
        let qwen = qwenLine(stdout)
        var after = ""
        if let qwen, let colon = qwen.firstIndex(of: ":") {
            after = String(qwen[qwen.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let first = after.split(whereSeparator: \.isWhitespace).first.map { String($0) } ?? ""
        let power: State.Power = first == "ON" || after.hasPrefix("already ON") ? .on : .off
        var project = ""
        if let qwen, let range = qwen.range(of: "working for ") {
            let rest = qwen[range.upperBound...]
            let end = rest.firstIndex(of: ")") ?? rest.endIndex
            project = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        }
        if project.isEmpty, let line = lines(stdout).last(where: { $0.hasPrefix("Project:") }),
           let colon = line.firstIndex(of: ":") {
            project = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if project == "nobody" { project = "" }
        return State(power: power, ok: true, project: project, message: "")
    }

    private static func qwenLine(_ stdout: String) -> String? { lines(stdout).last { $0.hasPrefix("Qwen server:") } }

    private static func stopped(_ stdout: String) -> String? { lines(stdout).first { $0.hasPrefix("STOPPED:") } }

    private static func lines(_ stdout: String) -> [String] { stdout.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) } }

    private static func folder(in file: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: start)
        let tail = (try? handle.readToEnd()) ?? Data()
        if let path = lastCwd(in: String(decoding: tail, as: UTF8.self)) { return URL(fileURLWithPath: path) }
        guard start > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        let whole = (try? handle.readToEnd()) ?? Data()
        guard let path = lastCwd(in: String(decoding: whole, as: UTF8.self)) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func lastCwd(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""cwd":"([^"]+)""#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
