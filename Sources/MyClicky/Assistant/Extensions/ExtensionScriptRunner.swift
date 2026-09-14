import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "extensions.runner")

/// Runs the scripts and tools an extension declares. Everything goes through
/// one `Process` path with an environment that tells the script who called
/// it (`PEEKY_*`), optional stdin, and a hard timeout — a stuck formatter
/// must never wedge the panel.
enum ExtensionScriptRunner {
    struct Invocation: Sendable {
        var executable: URL
        var arguments: [String]
        var currentDirectory: URL
        var environment: [String: String] = [:]
        var stdin: String?
        var timeout: TimeInterval = 30
    }

    enum Failure: LocalizedError, Equatable {
        case notFound(String)
        case timedOut(TimeInterval)
        case launch(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let command): return "“\(command)” isn't installed (not on PATH)."
            case .timedOut(let seconds): return "Gave up after \(Int(seconds)) s."
            case .launch(let detail): return detail
            }
        }
    }

    /// Where `command` resolves: an absolute/relative path as given, or a
    /// lookup along a PATH that includes the usual Homebrew/npm spots even
    /// when Peeky was launched from Finder with a bare environment.
    static func resolve(command: String, cwd: URL) -> URL? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        if command.contains("/") {
            let url = cwd.appendingPathComponent(command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for dir in searchPath() {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func searchPath() -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                      "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return (inherited + extras).filter { seen.insert($0).inserted }
    }

    static func run(_ invocation: Invocation) async throws -> CommandResult {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath().joined(separator: ":")
        for (key, value) in invocation.environment { env[key] = value }
        process.environment = env

        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input

        do { try process.run() } catch { throw Failure.launch(error.localizedDescription) }

        if let stdin = invocation.stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? input.fileHandleForWriting.close()

        let outTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        let killed = TimeoutFlag()
        let deadline = Task.detached { [timeout = invocation.timeout] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                killed.set()
                process.terminate()
            }
        }
        await Task.detached { process.waitUntilExit() }.value
        deadline.cancel()
        let stdout = String(decoding: await outTask.value, as: UTF8.self)
        let stderr = String(decoding: await errTask.value, as: UTF8.self)
        if killed.isSet { throw Failure.timedOut(invocation.timeout) }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: Actions

    /// Runs an action's script. Params reach it three ways: `$1…` in
    /// declaration order, `PEEKY_PARAM_<NAME>` variables, and a JSON object
    /// on stdin — whichever is most natural for the runner in use.
    static func runAction(_ action: ExtensionManifest.Action, in folder: URL, extensionID: String,
                          params: [String: String], context: [String: String] = [:]) async throws -> CommandResult {
        let script = folder.appendingPathComponent(action.script).standardizedFileURL
        guard script.path.hasPrefix(folder.standardizedFileURL.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw Failure.notFound(action.script)
        }
        let runner = ExtensionRunner(rawValue: action.runner ?? "shell") ?? .shell
        let ordered = (action.params ?? []).map { params[$0.name] ?? "" }
        var env = context
        env["PEEKY_EXTENSION_ID"] = extensionID
        env["PEEKY_EXTENSION_DIR"] = folder.path
        env["PEEKY_VERB"] = action.verb
        for (name, value) in params {
            env["PEEKY_PARAM_" + name.uppercased().replacingOccurrences(of: "-", with: "_")] = value
        }
        let json = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let executable: URL
        var arguments: [String]
        switch runner {
        case .shell:
            executable = URL(fileURLWithPath: "/bin/zsh")
            arguments = [script.path] + ordered
        case .applescript:
            executable = URL(fileURLWithPath: "/usr/bin/osascript")
            arguments = [script.path] + ordered
        case .javascript:
            executable = URL(fileURLWithPath: "/usr/bin/osascript")
            arguments = ["-l", "JavaScript", script.path] + ordered
        }
        log.notice("running \(extensionID, privacy: .public)/\(action.verb, privacy: .public) via \(runner.rawValue, privacy: .public)")
        return try await run(Invocation(executable: executable, arguments: arguments, currentDirectory: folder,
                                        environment: env, stdin: json, timeout: action.timeout ?? 60))
    }

    // MARK: Formatters & linters

    /// `${file}` → absolute path, `${name}` → file name, `${dir}` → its folder,
    /// `${project}` → project root, `${ext}` → the extension's own folder.
    static func substitute(_ args: [String], file: URL, project: URL, extensionDir: URL) -> [String] {
        args.map {
            $0.replacingOccurrences(of: "${file}", with: file.path)
              .replacingOccurrences(of: "${name}", with: file.lastPathComponent)
              .replacingOccurrences(of: "${dir}", with: file.deletingLastPathComponent().path)
              .replacingOccurrences(of: "${project}", with: project.path)
              .replacingOccurrences(of: "${ext}", with: extensionDir.path)
        }
    }

    struct FormatResult: Equatable, Sendable {
        let text: String
        let changed: Bool
    }

    /// Formats `text` (the editor's copy of `file`). Stdin formatters never
    /// touch disk; in-place ones get the current text written first so what
    /// they format is what's on screen, then the file is read back.
    static func format(_ formatter: ExtensionManifest.Formatter, text: String, file: URL, project: URL,
                       extensionDir: URL) async throws -> FormatResult {
        guard let executable = resolve(command: formatter.command, cwd: project) else {
            throw Failure.notFound(formatter.command)
        }
        let args = substitute(formatter.args ?? [], file: file, project: project, extensionDir: extensionDir)
        let env = ["PEEKY_FILE": file.path, "PEEKY_PROJECT": project.path, "PEEKY_EXTENSION_DIR": extensionDir.path]
        if formatter.stdin ?? true {
            let result = try await run(Invocation(executable: executable, arguments: args, currentDirectory: project,
                                                  environment: env, stdin: text, timeout: formatter.timeout ?? 30))
            guard result.status == 0 else { throw Failure.launch(firstLine(result.stderr.isEmpty ? result.stdout : result.stderr)) }
            return FormatResult(text: result.stdout, changed: result.stdout != text)
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        let result = try await run(Invocation(executable: executable, arguments: args, currentDirectory: project,
                                              environment: env, timeout: formatter.timeout ?? 30))
        guard result.status == 0 else { throw Failure.launch(firstLine(result.stderr.isEmpty ? result.stdout : result.stderr)) }
        let formatted = try String(contentsOf: file, encoding: .utf8)
        return FormatResult(text: formatted, changed: formatted != text)
    }

    struct LintFinding: Equatable, Sendable, Identifiable {
        /// 1-based
        let line: Int
        /// 1-based, 0 when the tool didn't say
        let column: Int
        /// 1 error, 2 warning, 3 info — the LSP scale the editor already draws.
        let severity: Int
        let message: String
        let source: String
        var id: String { "\(line):\(column):\(severity):\(message)" }
    }

    /// Runs a linter and parses each output line against its `pattern`.
    /// Non-zero exit is normal for a linter with findings, so only "couldn't
    /// run at all" is an error here.
    static func lint(_ linter: ExtensionManifest.Linter, text: String, file: URL, project: URL,
                     extensionDir: URL) async throws -> [LintFinding] {
        guard let executable = resolve(command: linter.command, cwd: project) else {
            throw Failure.notFound(linter.command)
        }
        let args = substitute(linter.args ?? [], file: file, project: project, extensionDir: extensionDir)
        let env = ["PEEKY_FILE": file.path, "PEEKY_PROJECT": project.path, "PEEKY_EXTENSION_DIR": extensionDir.path]
        let result = try await run(Invocation(executable: executable, arguments: args, currentDirectory: project,
                                              environment: env, stdin: (linter.stdin ?? false) ? text : nil,
                                              timeout: linter.timeout ?? 30))
        if result.status == 127 { throw Failure.notFound(linter.command) }
        let findings = parseFindings(result.stdout + "\n" + result.stderr, pattern: linter.pattern, source: linter.name)
        if findings.isEmpty, result.status != 0, !result.stderr.isEmpty, result.stdout.isEmpty {
            // Nothing matched and it complained: most likely a crash or a
            // missing config, not a clean file — surface it.
            throw Failure.launch(firstLine(result.stderr))
        }
        return findings
    }

    static func parseFindings(_ output: String, pattern: String, source: String) -> [LintFinding] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var findings: [LintFinding] = []
        let ns = output as NSString
        regex.enumerateMatches(in: output, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            func group(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            guard let lineText = group("line"), let line = Int(lineText), line > 0,
                  let message = group("message")?.trimmingCharacters(in: .whitespaces), !message.isEmpty else { return }
            let column = group("col").flatMap(Int.init) ?? 0
            let severity: Int = {
                switch group("severity")?.lowercased() {
                case "error", "e", "fatal": return 1
                case "info", "note", "hint", "i": return 3
                case nil: return 2
                default: return 2
                }
            }()
            findings.append(LintFinding(line: line, column: column, severity: severity, message: message, source: source))
        }
        var seen = Set<String>()
        return findings.filter { seen.insert($0.id).inserted }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "failed"
    }
}
