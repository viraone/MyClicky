import AppKit
import SwiftTerm
import SwiftUI

/// The Terminal tab: a real shell (the user's login shell) running inside
/// Peeky, started in the Peeky Code project's folder so `git status`,
/// `git push`, `npm start` and friends just work. Nothing here talks to
/// Claude — it costs nothing to use.
@MainActor
final class TerminalSession: ObservableObject {
    let view: LocalProcessTerminalView
    /// Folder the shell was started in, so a project change can restart it.
    private(set) var startedIn: URL?
    private(set) var running = false

    init() {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        view.nativeForegroundColor = NSColor.white.withAlphaComponent(0.92)
        view.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.caretColor = .white
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
    }

    /// Starts the shell if it isn't running. A different folder restarts it
    /// there, since a running shell can't be told to `cd` from outside.
    func start(in directory: URL?) {
        let target = directory ?? FileManager.default.homeDirectoryForCurrentUser
        if running, startedIn == target { return }
        if running { stop() }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        env.append("PEEKY=1")
        FileManager.default.changeCurrentDirectoryPath(target.path)
        view.startProcess(executable: shell, args: ["-l"], environment: env, execName: (shell as NSString).lastPathComponent)
        startedIn = target
        running = true
    }

    func stop() {
        view.process.terminate()
        running = false
    }

    func processTerminated() { running = false }

    /// Terminal.app's ⌘K: wipe the screen and scrollback, keep the prompt.
    /// Redraw the prompt by nudging the shell, so it doesn't look hung.
    func clearScreen() {
        view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        if running { view.send(txt: "\u{0c}") }  // ⌃L: zsh/bash repaint the prompt
    }
}

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view.processDelegate = context.coordinator
        return session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.focusWhenMounted(view)
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.focusRequest?.cancel()
        coordinator.removeClickMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator(session) }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        private var didFocus = false
        fileprivate var focusRequest: DispatchWorkItem?
        private var clickMonitor: Any?
        init(_ session: TerminalSession) { self.session = session }

        func focusWhenMounted(_ view: LocalProcessTerminalView) {
            installClickMonitorIfNeeded(for: view)
            guard !didFocus else { return }
            focusRequest?.cancel()
            // SwiftUI attaches the view after updateNSView. Focus once per
            // mount so later updates don't steal focus from another field.
            let request = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view, let window = view.window,
                      !view.isHiddenOrHasHiddenAncestor else { return }
                // Peeky is a non-activating, becomesKeyOnlyIfNeeded panel.
                // A plain NSView like the terminal never asks AppKit to make
                // the panel key, so without this ⌘-shortcuts (⌘K, ⌘V…)
                // silently go nowhere: performKeyEquivalent only fires on
                // the key window.
                window.makeKey()
                self.didFocus = window.makeFirstResponder(view)
            }
            focusRequest = request
            DispatchQueue.main.async(execute: request)
        }

        /// Clicking straight into the terminal (rather than switching tabs)
        /// hits the same "never asks to become key" gap, since it's a plain
        /// NSView. Promote the panel to key on any click while this tab is
        /// mounted, so a ⌘-shortcut pressed right after actually arrives.
        private func installClickMonitorIfNeeded(for view: LocalProcessTerminalView) {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
                if let window = view?.window, event.window === window, !window.isKeyWindow {
                    window.makeKey()
                }
                return event
            }
        }

        fileprivate func removeClickMonitor() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in
                session.processTerminated()
                source.feed(text: "\r\n\u{1b}[2m[shell exited\(exitCode.map { " (\($0))" } ?? "") — click ↻ to start a new one]\u{1b}[0m\r\n")
            }
        }
    }
}
