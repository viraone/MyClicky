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

    /// What one chat's record file said the last time its modification date
    /// changed. The phone asks for the chat in front every 2 s, so a file
    /// whose modification date has not moved is not read again.
    private struct ChatRecord {
        var modificationDate: Date?
        var lastFocusedAt: Double?
        var cwd: String
        var isArchived: Bool
    }

    /// One record per `local_*.json` path, kept between scans.
    private static var chatRecords: [String: ChatRecord] = [:]

    private static let sessionsRoot = home.appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    /// The folder of the chat in front in the Claude desktop app. The app
    /// keeps a record per chat (folder, title, `lastFocusedAt`, archived), so
    /// the chat you most recently clicked into is the one in front, even if
    /// another chat wrote to its transcript more recently. The newest
    /// transcript is only a fallback for a Mac with no session records yet.
    static func activeChatFolder() -> URL? {
        if FileManager.default.fileExists(atPath: sessionsRoot.path) {
            return focusedChatFolder()
        }
        return newestTranscriptFolder()
    }

    private static func focusedChatFolder() -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sessionsRoot,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var bestFocus = -1.0
        var bestFolder: String?
        var seen: Set<String> = []
        for case let file as URL in walker {
            guard file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json" else { continue }
            seen.insert(file.path)
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let record: ChatRecord
            if let modified, let cached = chatRecords[file.path], cached.modificationDate == modified {
                record = cached
            } else {
                record = readChatRecord(file, modified: modified)
                chatRecords[file.path] = record
            }
            guard !record.isArchived, let focus = record.lastFocusedAt,
                  !record.cwd.isEmpty, focus > bestFocus else { continue }
            bestFocus = focus
            bestFolder = record.cwd
        }
        chatRecords = chatRecords.filter { seen.contains($0.key) }
        guard let bestFolder, fm.fileExists(atPath: bestFolder) else { return nil }
        return URL(fileURLWithPath: bestFolder)
    }

    private static func readChatRecord(_ file: URL, modified: Date?) -> ChatRecord {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ChatRecord(modificationDate: modified, lastFocusedAt: nil, cwd: "", isArchived: false)
        }
        return ChatRecord(modificationDate: modified,
                          lastFocusedAt: (json["lastFocusedAt"] as? NSNumber)?.doubleValue,
                          cwd: json["cwd"] as? String ?? "",
                          isArchived: (json["isArchived"] as? Bool) == true)
    }

    /// The project of the chat in front, for the phone's STACK key; empty
    /// when that chat is not inside one of the known repos.
    static func frontProject() -> String {
        activeChatFolder().map(projectName(forFolder:)) ?? ""
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
        if let switched = switchedTo(stdout) {
            state.message = "Stack switched to \(displayName(switched)) — Qwen ready"
            return state
        }
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
        return State(power: power, ok: true, project: displayName(project), message: "")
    }

    /// The name the phone and the toast show for one of stack.sh's projects.
    static func displayName(_ project: String) -> String {
        switch project {
        case "beezer": "Beezer"
        case "seo-audit": "SEO Tuneup"
        case "myclicky": "Peeky"
        case "nocapedit": "NoCap Edit"
        default: project
        }
    }

    /// The display name of the project whose repo holds `folder`, the same
    /// mapping stack.sh makes for `on` with no project; empty when the folder
    /// is inside none of them (the phone then shows no project at all).
    static func projectName(forFolder folder: URL) -> String {
        // Resolve symlinks on both sides: ~/Desktop/beezer is a link to
        // ~/Developer/beezer, and some chats are recorded under the Desktop
        // path. stack.sh sees the physical path, so the phone must too.
        let path = folder.resolvingSymlinksInPath().path + "/"
        let repos: [(String, String)] = [
            ("Developer/beezer", "beezer"), ("Developer/seo-audit", "seo-audit"),
            ("Developer/MyClicky1", "myclicky"), ("Desktop/Projects/reelflowWeb", "nocapedit"),
        ]
        for (repo, project) in repos {
            let root = home.appendingPathComponent(repo, isDirectory: true).resolvingSymlinksInPath().path + "/"
            if path.hasPrefix(root) { return displayName(project) }
        }
        return ""
    }

    /// The project Qwen was handed from another one, when stack.sh's Qwen
    /// line says "… (switched from X to Y)".
    private static func switchedTo(_ stdout: String) -> String? {
        guard let qwen = qwenLine(stdout), let from = qwen.range(of: "switched from ") else { return nil }
        let rest = qwen[from.upperBound...]
        guard let to = rest.range(of: " to ") else { return nil }
        let project = rest[to.upperBound...].prefix { !$0.isWhitespace && $0 != ")" }
        return project.isEmpty ? nil : String(project)
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
