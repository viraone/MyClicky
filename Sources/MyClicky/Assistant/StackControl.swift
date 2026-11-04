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

    /// The folder of the chat in front in the Claude desktop app. The app
    /// keeps a record per chat (folder, title, `lastFocusedAt`, archived), so
    /// the chat you most recently clicked into is the one in front, even if
    /// another chat wrote to its transcript more recently. If that record is
    /// not there, fall back to the newest transcript.
    static func activeChatFolder() -> URL? {
        focusedChatFolder() ?? newestTranscriptFolder()
    }

    private static func focusedChatFolder() -> URL? {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions",
                                               isDirectory: true)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return nil }
        var bestFocus = -1.0
        var bestFolder: String?
        for case let file as URL in walker {
            guard file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["isArchived"] as? Bool) != true,
                  let focus = (json["lastFocusedAt"] as? NSNumber)?.doubleValue,
                  let cwd = json["cwd"] as? String, !cwd.isEmpty,
                  focus > bestFocus else { continue }
            bestFocus = focus
            bestFolder = cwd
        }
        guard let bestFolder, FileManager.default.fileExists(atPath: bestFolder) else { return nil }
        return URL(fileURLWithPath: bestFolder)
    }

    /// Fallback: the newest transcript under ~/.claude/projects, and the last
    /// "cwd" it holds.
    private static func newestTranscriptFolder() -> URL? {
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
        let (stdout, error) = await run("status", in: home, timeout: 30, onLine: { _ in })
        guard let stdout else { return State(power: .off, ok: false, project: "", message: error ?? "stack.sh failed") }
        return parsed(stdout)
    }

    static func turnOn(onLine: @escaping @MainActor (String) -> Void) async -> State {
        let (stdout, error) = await run("on", in: activeChatFolder() ?? home, timeout: 300, onLine: onLine)
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

    static func turnOff(onLine: @escaping @MainActor (String) -> Void) async -> State {
        let (stdout, error) = await run("off", in: home, timeout: 120, onLine: onLine)
        guard let stdout else { return State(power: .off, ok: false, project: "", message: error ?? "stack.sh failed") }
        if let stopped = stopped(stdout) {
            let now = await status()
            return State(power: now.power, ok: false, project: now.project, message: stopped)
        }
        var state = parsed(stdout)
        state.message = "Stack OFF — everything stopped"
        return state
    }

    /// Runs `stack.sh` and hands every stdout line to `onLine` as it arrives,
    /// so the phone can show the steps while the command is still running.
    /// The whole stdout is also returned for the parsers below.
    private static func run(_ action: String, in folder: URL, timeout: TimeInterval,
                            onLine: @escaping @MainActor (String) -> Void) async -> (stdout: String?, error: String?) {
        guard FileManager.default.fileExists(atPath: script.path) else { return (nil, "stack.sh not found") }
        var environment = ProcessInfo.processInfo.environment
        environment["STACK_START_DEV"] = "1"
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let inherited = environment["PATH"], !inherited.isEmpty { path += ":" + inherited }
        environment["PATH"] = path

        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, action]
            process.currentDirectoryURL = folder
            process.environment = environment
            process.standardOutput = pipe
            // The old runner closed stdin and discarded stderr; keep that.
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // The readability and termination handlers arrive on different
            // background threads, so this serial queue owns the buffers and
            // guarantees the continuation resumes exactly once.
            let state = DispatchQueue(label: "com.myclicky.stack-control")
            var collected = Data()
            var pending = Data()
            var resumed = false
            var timedOut = false

            func emit(_ line: Data) {
                let text = String(decoding: line, as: UTF8.self)
                Task { @MainActor in onLine(text) }
            }

            func consume(_ chunk: Data) {
                guard !chunk.isEmpty else { return }
                collected.append(chunk)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    var line = pending[pending.startIndex..<newline]
                    if line.last == 0x0D { line = line.dropLast() }
                    pending.removeSubrange(pending.startIndex...newline)
                    emit(Data(line))
                }
            }

            func finish(_ result: (stdout: String?, error: String?)) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                state.async { consume(data) }
            }

            var timeoutTask: Task<Void, Never>? = nil
            process.terminationHandler = { _ in
                timeoutTask?.cancel()
                // Never wait for the pipe to hit end-of-file: the dev server
                // stack.sh starts runs under a background wrapper that keeps
                // the pipe's write end open for as long as the server lives,
                // so a read-to-EOF here would never return and the phone
                // would sit on "working" forever. The script has exited, so
                // give the reader a moment to deliver its last lines and go.
                state.asyncAfter(deadline: .now() + 0.4) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if !pending.isEmpty {
                        emit(pending)
                        pending.removeAll()
                    }
                    if timedOut {
                        finish((nil, "stack.sh timed out after \(Int(timeout)) s"))
                    } else {
                        finish((String(decoding: collected, as: UTF8.self), nil))
                    }
                }
            }

            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, process.isRunning else { return }
                state.async {
                    guard !resumed else { return }
                    timedOut = true
                }
                process.terminate()
            }

            do {
                try process.run()
            } catch {
                timeoutTask?.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (nil, error.localizedDescription))
            }
        }
    }

    /// One `stack.sh` output line as a STACK_STEP wire line, or nil when the
    /// line is not a step the phone should draw.
    static func stepLine(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("STOPPED:") {
            let detail = stepDetail(String(trimmed.dropFirst("STOPPED:".count)))
            return "STACK_STEP FAIL\tStopped\t\(detail)"
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard stepLabels.contains(label) else { return nil }
        let shown = label == "Qwen server" ? "Qwen"
                  : label == "Local Supabase" ? "Supabase"
                  : label
        var detail = stepDetail(String(trimmed[trimmed.index(after: colon)...]))
        var state = "DONE"
        if detail.hasSuffix("...") {
            detail = String(detail.dropLast(3)).trimmingCharacters(in: .whitespaces)
            state = "DOING"
        } else if detail.hasSuffix("…") {
            detail = String(detail.dropLast()).trimmingCharacters(in: .whitespaces)
            state = "DOING"
        }
        return "STACK_STEP \(state)\t\(shown)\t\(detail)"
    }

    /// `stack.sh` labels the phone draws; every other line (Ollama, chatter)
    /// is ignored.
    private static let stepLabels: Set<String> = [
        "Project", "Database", "Docker", "Local Supabase", "Page", "Qwen server",
        "beezer", "seo-audit", "myclicky", "nocapedit",
    ]

    private static func stepDetail(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
