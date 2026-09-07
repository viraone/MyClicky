import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "messages")

/// Sending into Messages.app.
///
/// The rule this encodes: if a conversation is already open on screen, that
/// conversation is the recipient — no contact lookup, no guessing which of
/// three Noahs was meant. A name search only happens when Messages is sitting
/// on the conversation list with nothing open.
///
/// The open conversation is read from the window title, which Messages sets
/// to the person you're talking to ("Noah Baker", or a bare "+1 (206)
/// 639-1704" for an unsaved number) and leaves as "Messages" when no thread
/// is open. Its inner Accessibility tree is largely opaque, so the title is
/// the reliable signal available.
@MainActor
enum MessagesActions {
    static let bundleID = "com.apple.MobileSMS"

    static func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Who the open conversation is with, or nil when Messages is showing the
    /// list rather than a thread.
    static func openConversation() -> String? {
        conversationWindow()?.title
    }

    /// The conversation window and the name on it.
    ///
    /// Every window is checked rather than trusting `AXMainWindow`: opening a
    /// thread by URL leaves a stray 84×77 untitled window behind that becomes
    /// "main" and masks the real one, which reads as "no conversation open"
    /// when there plainly is.
    private static func conversationWindow() -> (element: AXUIElement, title: String)? {
        guard let app = running() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in AccessibilityFinder.windows(of: appElement) {
            guard let title = AccessibilityFinder.attribute(window, kAXTitleAttribute) as? String else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Messages" is the app's own name, shown when nothing is open.
            guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Messages") != .orderedSame else { continue }
            return (window, trimmed)
        }
        return nil
    }

    /// Opens the conversation with `number` and waits for it to actually be
    /// the one on screen.
    ///
    /// Via the `sms:` URL scheme rather than by driving the UI. Messages
    /// exposes almost nothing to Accessibility — clicking the sidebar row and
    /// typing into the search field both fail — and the URL is a documented,
    /// deterministic route that leaves the thread visible before anything is
    /// typed into it.
    static func openConversation(number: String) async -> Bool {
        let dialable = number.filter { $0.isNumber || $0 == "+" }
        guard !dialable.isEmpty, let url = URL(string: "sms:\(dialable)") else { return false }
        guard NSWorkspace.shared.open(url) else { return false }

        // Messages takes a moment to switch threads, and reporting success
        // before it has would let a send land in the previous conversation.
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let open = openConversation(), !open.isEmpty {
                let openDigits = open.filter(\.isNumber)
                let wantDigits = dialable.filter(\.isNumber)
                // Either the title became a name (a saved contact) or it shows
                // the number we asked for, allowing for country-code prefixes.
                if openDigits.isEmpty || openDigits.hasSuffix(wantDigits.suffix(7)) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether the name someone spoke plausibly refers to the conversation
    /// that's actually open.
    ///
    /// The point is to catch the one case that sends to the wrong person:
    /// saying "Dino Dad" while a different thread is in front. Selecting a
    /// row in the sidebar is what moves the window title — merely seeing a
    /// name in the list doesn't — so words and screen can disagree silently.
    ///
    /// Deliberately literal token containment, not a model call: Messages
    /// titles are a saved name or a bare phone number, and a send is not the
    /// place to add a network round trip that can itself be wrong.
    static func spokenNameMatches(_ spoken: String, conversation title: String) -> Bool {
        // Words that point at the open thread rather than naming a person —
        // "send this here" is agreeing with the screen, not contradicting it.
        let neutral: Set<String> = [
            "here", "this", "that", "it", "them", "him", "her", "they",
            "chat", "conversation", "thread", "the", "open", "current", "one",
        ]
        let spokenNames = tokens(spoken).filter { !neutral.contains($0) }
        guard !spokenNames.isEmpty else { return true }
        let titleTokens = Set(tokens(title))
        return spokenNames.allSatisfy(titleTokens.contains)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Types `text` into the open conversation and sends it. Returns false
    /// without sending anything if no conversation is open.
    @discardableResult
    static func sendToOpenConversation(_ text: String,
                                       status: @escaping (_ message: String, _ ok: Bool) -> Void) -> Bool {
        guard let app = running(), let recipient = openConversation() else {
            status("No conversation open in Messages — open one first.", false)
            return false
        }
        app.activate(options: [.activateAllWindows])
        usleep(400_000)

        guard let field = composeField(in: app) else {
            status("Couldn't find the message box in Messages.", false)
            return false
        }
        MouseClicker.click(at: NSPoint(x: field.midX, y: field.midY))
        usleep(250_000)

        // Paste rather than synthesise keystrokes: the passage being sent is
        // usually code, and synthetic Unicode events get mangled by exactly
        // the kind of view Messages uses.
        KeyboardTyper.paste(text)
        // A long multi-line paste makes Messages re-layout the compose box;
        // a Return that lands during that is dropped. Wait it out, then press
        // again after a beat — Return on an already-empty box does nothing.
        usleep(1_200_000)
        KeyboardTyper.press(KeyboardTyper.returnKey)
        usleep(700_000)
        KeyboardTyper.press(KeyboardTyper.returnKey)

        ActivityLog.recordAction("messages-send", ["to": recipient])
        status("Sent to \(recipient) in Messages", true)
        return true
    }

    /// Message text visible in the open conversation, top to bottom — what
    /// Accessibility exposes of the transcript, which is the bubbles' static
    /// text. Returns [] when Messages shows nothing readable.
    static func visibleTranscript(limit: Int = 24) -> [String] {
        guard let (window, _) = conversationWindow() else { return [] }
        var lines: [String] = []
        var seen = Set<String>()
        var budget = 0
        _ = AccessibilityFinder.search(window, budget: &budget) { element in
            guard let role = AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String,
                  role == kAXStaticTextRole,
                  let value = AccessibilityFinder.attribute(element, kAXValueAttribute) as? String else { return false }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Timestamps, "Delivered", "iMessage" and the like are short and
            // aren't the conversation.
            guard text.count > 2, !["Delivered", "Read", "iMessage", "Text Message", "SMS"].contains(text),
                  !seen.contains(text) else { return false }
            seen.insert(text)
            lines.append(text)
            return false
        }
        return Array(lines.suffix(limit))
    }

    /// Background counterpart of `typeIntoOpenConversation`: sets the compose
    /// box's value through Accessibility without activating Messages, so the
    /// app the user is working in keeps focus. Any `needsFallback` result
    /// means nothing was written — call `typeIntoOpenConversation` instead.
    static func writeIntoOpenConversationInBackground(_ text: String) -> BackgroundWriteResult {
        guard let app = running(), openConversation() != nil else { return .elementNotWritable }
        guard let field = composeElement(in: app) else {
            log.notice("background write: compose field not in the AX tree")
            return .elementNotWritable
        }
        return AXActions.writeTextInBackground(to: field, text: text)
    }

    /// Puts `text` into the compose box of the open conversation without
    /// sending it, replacing whatever was typed there. Returns false if no
    /// conversation is open.
    static func typeIntoOpenConversation(_ text: String) -> Bool {
        guard let app = running(), openConversation() != nil else { return false }
        app.activate(options: [.activateAllWindows])
        usleep(400_000)
        guard let field = composeField(in: app) else { return false }
        MouseClicker.click(at: NSPoint(x: field.midX, y: field.midY))
        usleep(250_000)
        KeyboardTyper.press(KeyboardTyper.aKey, flags: .maskCommand)
        usleep(100_000)
        KeyboardTyper.paste(text)
        return true
    }

    /// Sends whatever is typed in the open conversation's compose box.
    static func sendTyped(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        guard let app = running(), let recipient = openConversation() else {
            status("No conversation open in Messages — open one first.", false)
            return
        }
        app.activate(options: [.activateAllWindows])
        usleep(400_000)
        guard let field = composeField(in: app) else {
            status("Couldn't find the message box in Messages.", false)
            return
        }
        MouseClicker.click(at: NSPoint(x: field.midX, y: field.midY))
        usleep(250_000)
        KeyboardTyper.press(KeyboardTyper.returnKey)
        ActivityLog.recordAction("messages-send", ["to": recipient, "via": "typed"])
        status("Sent to \(recipient) in Messages", true)
    }

    /// The compose box. Tries the Accessibility tree first, then falls back to
    /// the bottom strip of the window — Messages exposes very little of itself
    /// to Accessibility, and the compose row is reliably the last thing above
    /// the window's bottom edge.
    private static func composeField(in app: NSRunningApplication) -> NSRect? {
        for placeholder in ["iMessage", "Text Message", "SMS", "Message"] {
            if let frame = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: placeholder, exact: false, onScreenOnly: true, quick: true
            ) {
                return frame
            }
        }
        guard let window = windowFrame(of: app) else { return nil }
        log.notice("compose field not in the AX tree — falling back to the window's bottom strip")
        return NSRect(x: window.midX - 40, y: window.minY + 34, width: 80, height: 12)
    }

    /// The compose box's AX element, when Messages exposes it at all (see
    /// `composeField` for why it often doesn't).
    private static func composeElement(in app: NSRunningApplication) -> AXUIElement? {
        for placeholder in ["iMessage", "Text Message", "SMS", "Message"] {
            if let element = AccessibilityFinder.element(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: placeholder, exact: false, onScreenOnly: true, quick: true
            ) {
                return element
            }
        }
        return nil
    }

    /// The conversation window's frame in AppKit coordinates (origin
    /// bottom-left), which is what `MouseClicker` expects.
    private static func windowFrame(of app: NSRunningApplication) -> NSRect? {
        guard let window = conversationWindow()?.element else { return nil }
        return AccessibilityFinder.frame(of: window)
    }
}
