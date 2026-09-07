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
/// so Clicky holds the line itself and it appears when it runs.
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

    struct Session {
        let app: NSRunningApplication
        let kind: Kind
        /// The front window, for the confirmation ring.
        let window: AXUIElement?

        var name: String { kind.name }
        var frame: NSRect? { window.flatMap(AccessibilityFinder.frame) }
    }

    /// The terminal to talk to: the frontmost one if a terminal is frontmost,
    /// else iTerm, else Terminal. nil when neither is open.
    static func session() -> Session? {
        let running = NSWorkspace.shared.runningApplications
        let candidates: [Session] = [Kind.iterm, .terminal].compactMap { kind in
            guard let app = running.first(where: { $0.bundleIdentifier == kind.bundleID }) else { return nil }
            let window = AccessibilityFinder.windows(of: AXUIElementCreateApplication(app.processIdentifier)).first
            return Session(app: app, kind: kind, window: window)
        }
        return candidates.first(where: { $0.app.isActive }) ?? candidates.first
    }

    /// Stages `text` at the prompt without Return. On iTerm the characters
    /// are really typed; on Terminal.app nothing is sent yet (see above).
    /// Returns whether the terminal accepted it.
    @discardableResult
    static func stage(_ text: String, in session: Session) -> Bool {
        switch session.kind {
        case .iterm:
            let ok = run("tell application \"iTerm\" to tell current session of current window to write text \(quoted(text)) newline NO") != nil
            ActivityLog.recordAction("terminal-stage", ["app": session.name, "chars": String(text.count), "ok": ok ? "yes" : "no"])
            return ok
        case .terminal:
            ActivityLog.recordAction("terminal-stage", ["app": session.name, "chars": String(text.count), "ok": "held"])
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
            ok = run("tell application \"iTerm\" to tell current session of current window to write text \"\"") != nil
        case .terminal:
            ok = run("tell application \"Terminal\" to do script \(quoted(text)) in selected tab of front window") != nil
        }
        ActivityLog.recordAction("terminal-run", ["app": session.name, "ok": ok ? "yes" : "no"])
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
            let ok = run("tell application \"iTerm\" to tell current session of current window to write text \(quoted(backspaces)) newline NO") != nil
            ActivityLog.recordAction("terminal-unstage", ["app": session.name, "chars": String(count), "ok": ok ? "yes" : "no"])
            return ok
        case .terminal:
            ActivityLog.recordAction("terminal-unstage", ["app": session.name, "chars": String(count), "ok": "held"])
            return true
        }
    }

    /// The visible text of the front tab, for verification.
    static func tabText(of session: Session) -> String? {
        switch session.kind {
        case .iterm: return run("tell application \"iTerm\" to tell current session of current window to get contents")
        case .terminal: return run("tell application \"Terminal\" to get contents of selected tab of front window")
        }
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
    /// What Clicky has staged at this prompt and not yet run or erased.
    private(set) var typed: String

    init(session: TerminalActions.Session, typed: String) {
        self.session = session
        self.typed = typed
    }

    var undoKey: AnyHashable { "terminal:\(session.app.processIdentifier)" }
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
