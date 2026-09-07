import AppKit
import ApplicationServices
import os

/// A terminal — Terminal.app or iTerm2 — as a write target, in the
/// background. The text reaches the tab through the terminal's own scripting
/// interface, so the window that has focus (usually the editor) keeps it, and
/// whatever is at the prompt gets the line: a shell, or a Claude Code /
/// Copilot CLI session waiting for its next instruction.
///
/// The draft model mirrors Messages: "tell the terminal …" stages the line,
/// "run it" commits it behind a confirm, "erase that" / "undo that" take it
/// back. Nothing runs on a bare dictation.
///
/// Why not keystrokes: a background Cocoa app has no key window, so key
/// events posted to its process are dropped; and `TIOCSTI` on the tab's tty
/// is root-only on macOS. iTerm can `write text … newline NO`, so there the
/// staged line is really at the prompt; Terminal.app can only `do script`,
/// so Peeky holds the line itself and it appears when it runs.
@MainActor
enum TerminalActions {
    private static let log = Logger(subsystem: "com.local.MyClicky", category: "TerminalActions")

    enum Kind {
        case terminal, iterm

        var bundleID: String {
            switch self {
            case .terminal: return "com.apple.Terminal"
            case .iterm: return "com.googlecode.iterm2"
            }
        }
        var name: String {
            switch self {
            case .terminal: return "Terminal"
            case .iterm: return "iTerm"
            }
        }
        /// Whether the staged line is visible at the prompt before it runs.
        var stagesAtPrompt: Bool { self == .iterm }
    }

    /// One tab (Terminal) or session (iTerm) — the unit a line goes into.
    struct Session {
        let app: NSRunningApplication
        let kind: Kind
        /// Terminal: `id of window`; iTerm: `id of session`.
        let windowID: String
        /// Terminal: 1-based tab index in that window. Unused for iTerm.
        let tabIndex: Int
        let tty: String
        /// The window's title, for the AX frame lookup and for saying which one.
        let title: String
        /// The tab the terminal itself would type into.
        let isSelected: Bool
        /// Front window first, as the terminal orders them.
        let windowOrder: Int
        /// Full command lines of what's running on the tty (from `ps`).
        let processes: [String]

        var name: String { kind.name }
        /// The coding agent at this prompt, if one is running here.
        var agent: String? { TerminalActions.agentName(in: processes) }
        /// "Claude Code in Terminal" / "Terminal".
        var label: String { agent.map { "\($0) in \(name)" } ?? name }

        var window: AXUIElement? {
            let all = AccessibilityFinder.windows(of: AXUIElementCreateApplication(app.processIdentifier))
            return all.first { (AccessibilityFinder.attribute($0, kAXTitleAttribute) as? String) == title } ?? all.first
        }
        var frame: NSRect? { window.flatMap(AccessibilityFinder.frame) }
        var screen: NSScreen? {
            guard let frame else { return nil }
            return NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
        }
    }

    /// Agents recognisable from their command line, and how to say them.
    nonisolated static let knownAgents: [(pattern: String, name: String)] = [
        ("claude", "Claude Code"),
        ("copilot", "Copilot CLI"),
        ("codex", "Codex"),
        ("gemini", "Gemini CLI"),
        ("aider", "Aider"),
        ("cursor", "Cursor Agent"),
        ("opencode", "OpenCode"),
    ]

    nonisolated static func agentName(in processes: [String]) -> String? {
        for line in processes {
            // The last path component of the executable, or the script a
            // node/python runtime is running ("node …/copilot/index.js").
            let lowered = line.lowercased()
            for agent in knownAgents where lowered.contains(agent.pattern) {
                // Require it as the command itself or a path segment
                // ("…/claude-code/cli.js", "@github/copilot"), not a
                // filename argument that merely mentions it.
                if lowered.range(of: "(^|[/\\s@])\(agent.pattern)([-_/\\s]|$)", options: .regularExpression) != nil {
                    return agent.name
                }
            }
        }
        return nil
    }

    /// The spoken agent, normalised to the name `agentName` produces; nil
    /// for "the agent" (any of them).
    nonisolated static func agentName(spoken: String) -> String? {
        // What the recognizer tends to hear for each name.
        let lowered = spoken.lowercased()
            .replacingOccurrences(of: "cloud", with: "claude")
            .replacingOccurrences(of: "co-pilot", with: "copilot")
            .replacingOccurrences(of: "co pilot", with: "copilot")
        return knownAgents.first { lowered.contains($0.pattern) }?.name
    }

    // MARK: - Enumeration

    /// Every tab in every running terminal, front window first.
    static func sessions() -> [Session] {
        let running = NSWorkspace.shared.runningApplications
        var result: [Session] = []
        for kind in [Kind.iterm, .terminal] {
            guard let app = running.first(where: { $0.bundleIdentifier == kind.bundleID }) else { continue }
            result += enumerate(kind, app: app)
        }
        return result
    }

    private static func enumerate(_ kind: Kind, app: NSRunningApplication) -> [Session] {
        let script: String
        switch kind {
        case .terminal:
            script = """
            tell application "Terminal"
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set out to out & (id of w) & "|" & ti & "|" & (tty of t) & "|" & (selected of t) & "|" & wi & "|" & (name of w) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm"
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        repeat with s in sessions of t
                            set sel to ((id of s) is (id of current session of t)) and ((id of t) is (id of current tab of w))
                            set out to out & (id of s) & "|" & ti & "|" & (tty of s) & "|" & sel & "|" & wi & "|" & (name of w) & linefeed
                        end repeat
                    end repeat
                end repeat
                return out
            end tell
            """
        }
        guard let out = run(script) else { return [] }
        return out.split(separator: "\n").compactMap { line -> Session? in
            // "tab" inside a `repeat with t in tabs` loop is the tab list, not the
            // character, so fields are pipe-separated; the title keeps any pipes.
            var f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.count > 6 { f = Array(f[0..<5]) + [f[5...].joined(separator: "|")] }
            guard f.count >= 6, let tab = Int(f[1]), let order = Int(f[4]) else { return nil }
            let tty = f[2]
            return Session(app: app, kind: kind, windowID: f[0], tabIndex: tab, tty: tty, title: f[5],
                           isSelected: f[3] == "true", windowOrder: order, processes: processes(onTTY: tty))
        }
    }

    /// `ps -t ttys003 -o args=` — what's running at that prompt.
    static func processes(onTTY tty: String) -> [String] {
        let short = tty.replacingOccurrences(of: "/dev/", with: "")
        guard !short.isEmpty else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-t", short, "-o", "args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Choosing

    struct Request {
        /// A named agent ("Claude Code"), or nil.
        var agent: String? = nil
        /// Any tab with an agent at the prompt ("tell the agent …").
        var anyAgent = false
        /// "…on the other screen": not the screen `avoiding` is on.
        var otherScreenThan: NSScreen? = nil
        /// "…on screen 2": 1-based display index in `NSScreen.screens`.
        var screenIndex: Int? = nil
    }

    enum Choice {
        case one(Session)
        case none
        case noAgent(String)
        case noTerminal
        /// "Screen 3" when there are two.
        case noScreen(Int)
    }

    /// Picks the tab a line should go to. Agent requests only consider tabs
    /// running that agent; otherwise the selected tab of the front window
    /// wins, unless a screen hint says otherwise. With windows on two
    /// displays and no hint, the one that isn't under the app you're working
    /// in is preferred — that's the "other screen" the whole idea is about.
    static func choose(_ request: Request, workingScreen: NSScreen?) -> Choice {
        var all = sessions()
        guard !all.isEmpty else { return .noTerminal }
        if let agent = request.agent {
            all = all.filter { $0.agent == agent }
            if all.isEmpty { return .noAgent(agent) }
        } else if request.anyAgent {
            let agents = all.filter { $0.agent != nil }
            if agents.isEmpty { return .noAgent("a coding agent") }
            all = agents
        }
        if let index = request.screenIndex {
            guard index >= 1, index <= NSScreen.screens.count else { return .noScreen(index) }
            let screen = NSScreen.screens[index - 1]
            let onIt = all.filter { $0.screen == screen }
            if onIt.isEmpty { return .none }
            all = onIt
        } else if let avoid = request.otherScreenThan {
            let elsewhere = all.filter { $0.screen != nil && $0.screen != avoid }
            if elsewhere.isEmpty { return .none }
            all = elsewhere
        } else if let workingScreen, NSScreen.screens.count > 1 {
            let elsewhere = all.filter { $0.screen != nil && $0.screen != workingScreen }
            if !elsewhere.isEmpty { all = elsewhere }
        }
        // Selected tab of the frontmost remaining window.
        let ordered = all.sorted { a, b in
            if a.windowOrder != b.windowOrder { return a.windowOrder < b.windowOrder }
            return a.isSelected && !b.isSelected
        }
        return ordered.first.map { .one($0) } ?? .none
    }

    // MARK: - Writing

    /// Stages `text` at the prompt without Return. On iTerm the characters
    /// are really typed; on Terminal.app nothing is sent yet (see above).
    @discardableResult
    static func stage(_ text: String, in session: Session) -> Bool {
        switch session.kind {
        case .iterm:
            let ok = iterm(session, "write text \(quoted(text)) newline NO")
            ActivityLog.recordAction("terminal-stage", ["app": session.label, "chars": String(text.count), "ok": ok ? "yes" : "no"])
            return ok
        case .terminal:
            ActivityLog.recordAction("terminal-stage", ["app": session.label, "chars": String(text.count), "ok": "held"])
            return true
        }
    }

    /// Commits the staged line: Return on iTerm, `do script` on Terminal.app.
    /// Returns whether the line was seen in the tab afterwards (nil when the
    /// tab can't be read).
    static func run(_ text: String, in session: Session) -> Bool? {
        let ok: Bool
        switch session.kind {
        case .iterm:
            ok = iterm(session, "write text \"\"")
        case .terminal:
            ok = run("tell application \"Terminal\" to do script \(quoted(text)) in tab \(session.tabIndex) of window id \(session.windowID)") != nil
        }
        ActivityLog.recordAction("terminal-run", ["app": session.label, "ok": ok ? "yes" : "no"])
        guard ok else { return false }
        usleep(250_000)
        return tabText(of: session).map { $0.contains(text) }
    }

    /// Takes back `count` staged characters. Only iTerm has anything on
    /// screen to take back; on Terminal.app the held line is just dropped.
    static func unstage(_ count: Int, in session: Session) -> Bool {
        switch session.kind {
        case .iterm:
            let backspaces = String(repeating: "\u{7f}", count: max(0, count))
            let ok = iterm(session, "write text \(quoted(backspaces)) newline NO")
            ActivityLog.recordAction("terminal-unstage", ["app": session.label, "chars": String(count), "ok": ok ? "yes" : "no"])
            return ok
        case .terminal:
            ActivityLog.recordAction("terminal-unstage", ["app": session.label, "chars": String(count), "ok": "held"])
            return true
        }
    }

    /// The visible text of the tab, for verification.
    static func tabText(of session: Session) -> String? {
        switch session.kind {
        case .iterm: return itermValue(session, "contents")
        case .terminal: return run("tell application \"Terminal\" to get contents of tab \(session.tabIndex) of window id \(session.windowID)")
        }
    }

    /// Runs `command` on the iTerm session with this id, wherever it is.
    private static func iterm(_ session: Session, _ command: String) -> Bool {
        run("""
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is \(quoted(session.windowID)) then
                            tell s to \(command)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "missing"
        end tell
        """) == "ok"
    }

    private static func itermValue(_ session: Session, _ property: String) -> String? {
        let out = run("""
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is \(quoted(session.windowID)) then return \(property) of s
                    end repeat
                end repeat
            end repeat
            return ""
        end tell
        """)
        return out?.isEmpty == false ? out : nil
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            log.error("AppleScript failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result.stringValue ?? ""
    }
}

/// The staged line as an undo target: "undo that" takes it back through the
/// same background path; the prompt never sees Return.
@MainActor
final class TerminalLineTarget: WriteUndoTarget {
    let session: TerminalActions.Session
    /// What Peeky has staged at this prompt and not yet run or erased.
    private(set) var typed: String

    init(session: TerminalActions.Session, typed: String) {
        self.session = session
        self.typed = typed
    }

    var undoKey: AnyHashable { "terminal:\(session.kind.bundleID):\(session.windowID):\(session.tabIndex)" }
    var isValid: Bool { !session.app.isTerminated }
    var frame: CGRect? { session.frame }

    func currentValue() -> String? { typed }

    func restore(_ value: String) -> BackgroundWriteResult {
        guard TerminalActions.unstage(typed.count, in: session) else { return .verificationFailed }
        if !value.isEmpty, !TerminalActions.stage(value, in: session) { return .verificationFailed }
        typed = value
        return .success
    }

    /// The line has run; nothing left to undo here.
    func consume() { typed = "" }

    func setTyped(_ value: String) { typed = value }
}
