import AppKit

/// Gmail hot-key actions driven from the phone's GMAIL tab.
@MainActor
enum GmailActions {
    private static let composeURL = "https://mail.google.com/mail/u/0/#inbox?compose=new"

    /// Trashes the email currently open in the browser — after a confirm
    /// dialog on the Mac, with an 8-second Undo afterwards.
    static func trashOpen(auth: GoogleAuthService, confirm: ConfirmActionPanelController,
                          status: @escaping (_ message: String, _ ok: Bool) -> Void) async {
        guard let tab = BrowserTabReader.activeTab(), tab.url.contains("mail.google.com") else {
            status("Open an email in Gmail first.", false)
            return
        }
        let gmail = GmailService(auth: auth)
        guard let threadID = await resolveThreadID(url: tab.url, title: tab.title, gmail: gmail) else {
            status("Couldn't tell which email is open — open one from the inbox list.", false)
            return
        }
        guard let info = try? await gmail.threadInfo(id: threadID) else {
            status("Couldn't look up that email.", false)
            return
        }
        let subject = info.subject.isEmpty ? "(no subject)" : info.subject
        let sender = info.from.replacingOccurrences(of: #"\s*<.*>"#, with: "", options: .regularExpression)
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        confirm.show(
            title: "Move to Trash?",
            message: "“\(subject)” from \(sender) will go to Gmail's Trash. You can restore it for 30 days.",
            confirmLabel: "Move to Trash",
            near: cursor,
            on: screen
        ) { confirmed in
            guard confirmed else { status("Cancelled — nothing was trashed.", true); return }
            Task {
                do {
                    try await gmail.trashThread(id: threadID)
                    ActivityLog.recordAction("gmail-trash", ["subject": subject])
                    navigate(to: "https://mail.google.com/mail/u/0/#inbox")
                    status("Moved to Trash", true)
                    confirm.show(
                        title: "Moved to Trash",
                        message: "“\(subject)” — changed your mind?",
                        confirmLabel: "Undo",
                        icon: "arrow.uturn.backward",
                        tint: .blue,
                        near: cursor,
                        on: screen
                    ) { undo in
                        guard undo else { return }
                        Task {
                            do {
                                try await gmail.untrashThread(id: threadID)
                                ActivityLog.recordAction("gmail-untrash", ["subject": subject])
                                navigate(to: "https://mail.google.com/mail/u/0/#inbox/\(threadID)")
                                status("Restored to Inbox", true)
                            } catch {
                                status("Undo failed: \(error.localizedDescription)", false)
                            }
                        }
                    }
                    try? await Task.sleep(for: .seconds(8))
                    confirm.hide()
                } catch {
                    status("Trash failed: \(error.localizedDescription)", false)
                }
            }
        }
    }

    /// Gmail URLs end in either the API thread ID (hex) or an opaque view ID.
    /// For the latter, fall back to matching the page title's subject.
    private static func resolveThreadID(url: String, title: String, gmail: GmailService) async -> String? {
        if let fragment = url.split(separator: "#").last,
           let last = fragment.split(separator: "/").last {
            let candidate = String(last).split(separator: "?").first.map(String.init) ?? ""
            if candidate.range(of: #"^[0-9a-f]{12,20}$"#, options: .regularExpression) != nil {
                return candidate
            }
            // A bare view like "#inbox" has no thread open.
            if fragment.split(separator: "/").count < 2 { return nil }
        }
        // Title looks like "Subject - you@gmail.com - Gmail".
        var subject = title
        if let range = subject.range(of: " - ", options: .backwards) { subject = String(subject[..<range.lowerBound]) }
        if let range = subject.range(of: " - ", options: .backwards) { subject = String(subject[..<range.lowerBound]) }
        subject = subject.trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty, subject.lowercased() != "inbox" else { return nil }
        return try? await gmail.findThread(subject: subject)
    }

    /// Opens the newest Primary-inbox email in the browser.
    static func openLatest(auth: GoogleAuthService) async {
        ActivityLog.recordAction("gmail-open-latest")
        let gmail = GmailService(auth: auth)
        guard let threadID = try? await gmail.latestInboxThreadID() else {
            navigate(to: "https://mail.google.com/mail/u/0/#inbox")
            return
        }
        navigate(to: "https://mail.google.com/mail/u/0/#inbox/\(threadID)")
    }

    /// Reuse the active Gmail tab if there is one, else open a new one.
    private static func navigate(to url: String) {
        let reused = BrowserTabReader.navigateActiveTab(
            matching: { $0.contains("mail.google.com") },
            to: url
        )
        if !reused, let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }

    /// Opens a new compose window. Reuses the active Gmail tab when the browser
    /// is already on Gmail; otherwise opens Gmail in the default browser.
    static func compose() {
        ActivityLog.recordAction("gmail-compose")
        navigate(to: composeURL)
    }

    /// Returns to the inbox list.
    static func openInbox() {
        ActivityLog.recordAction("gmail-inbox")
        navigate(to: "https://mail.google.com/mail/u/0/#inbox")
    }

    /// Clicks into the Subject field of the compose window open in Gmail.
    static func focusSubject(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("gmail-focus-subject")
        focusComposeField(js: "input[name=subjectbox]", axName: "subject", label: "Subject", status: status)
    }

    /// Clicks into the message body of the compose window open in Gmail.
    static func focusBody(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("gmail-focus-body")
        focusComposeField(js: "div[aria-label='Message Body']", axName: "message body", label: "Body", status: status)
    }

    /// Clicks Send on the compose window open in Gmail. Gmail's own Undo
    /// toast stays available for a few seconds afterwards.
    static func send(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("gmail-send")
        let isGmail: (String) -> Bool = { $0.contains("mail.google.com") }
        guard let browser = BrowserTabReader.runningBrowser(withTabMatching: isGmail) else {
            status("Open Gmail in your browser first.", false)
            return
        }
        browser.activate()

        let js = """
        (function(){var a=Array.prototype.slice.call(document.querySelectorAll('div[role=button][aria-label^=Send]')).filter(function(e){return e.offsetParent!==null;});var el=a[a.length-1];if(!el){return 'none';}el.click();return 'ok';})()
        """
        switch BrowserTabReader.runJavaScript(js, inTabMatching: isGmail) {
        case "ok":
            status("Sent", true)
            return
        case "none":
            status("No compose window open — nothing to send.", false)
            return
        default:
            break // JavaScript from Apple Events is disabled; use Accessibility.
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let frame = AccessibilityFinder.buttonFrame(in: browser, matching: "send") else {
                status("Couldn't find the Send button — is a compose window open?", false)
                return
            }
            MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
            status("Sent", true)
        }
    }

    /// Clicks Reply on the email open in Gmail. Gmail opens the reply editor
    /// with the cursor already in the message body, so the next step is
    /// typing (or dictating) and then Send.
    static func reply(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("gmail-reply")
        let isGmail: (String) -> Bool = { $0.contains("mail.google.com") }
        guard let browser = BrowserTabReader.runningBrowser(withTabMatching: isGmail) else {
            status("Open Gmail in your browser first.", false)
            return
        }
        browser.activate()

        // Prefer the "Reply" link under the message (its label is plain text,
        // no aria-label); fall back to the toolbar icon, which may be scrolled
        // off to the right. Only elements inside the viewport count.
        let js = """
        (function(){function vis(e){if(!e.offsetParent)return false;var r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.right>0&&r.bottom>0&&r.left<window.innerWidth&&r.top<window.innerHeight;}var links=Array.prototype.slice.call(document.querySelectorAll("span[role=link],div[role=button],span[role=button]")).filter(function(e){var t=(e.textContent||'').trim();var l=(e.getAttribute('aria-label')||e.getAttribute('data-tooltip')||'').trim();return (t==='Reply'||l==='Reply')&&vis(e);});var el=links.filter(function(e){return e.getAttribute('role')==='link';}).pop()||links.pop();if(!el){return 'none';}el.click();return 'ok';})()
        """
        switch BrowserTabReader.runJavaScript(js, inTabMatching: isGmail) {
        case "ok":
            status("Replying — type your message, then Send", true)
            return
        case "none":
            status("No email open — open one first (try Latest).", false)
            return
        default:
            break // JavaScript from Apple Events is disabled; use Accessibility.
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let frame = AccessibilityFinder.visibleControlFrame(in: browser, titled: "Reply") else {
                status("Couldn't find the Reply button — is an email open?", false)
                return
            }
            MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
            status("Replying — type your message, then Send", true)
        }
    }

    /// Clicks into a compose-window field. Tries in-page JavaScript first
    /// (needs "Allow JavaScript from Apple Events" in the browser), then falls
    /// back to locating the field through Accessibility and clicking it for real.
    private static func focusComposeField(js selector: String, axName: String, label: String,
                                          status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        let isGmail: (String) -> Bool = { $0.contains("mail.google.com") }
        guard let browser = BrowserTabReader.runningBrowser(withTabMatching: isGmail) else {
            status("Open Gmail in your browser first.", false)
            return
        }
        browser.activate()

        // Visible matches only; the last one is the most recent compose.
        let js = """
        (function(){var a=Array.prototype.slice.call(document.querySelectorAll("\(selector)")).filter(function(e){return e.offsetParent!==null;});var el=a[a.length-1];if(!el){return 'none';}el.focus();el.click();return 'ok';})()
        """
        switch BrowserTabReader.runJavaScript(js, inTabMatching: isGmail) {
        case "ok":
            status(label, true)
            return
        case "none":
            status("No compose window open — press Compose first.", false)
            return
        default:
            break // JavaScript from Apple Events is disabled; use Accessibility.
        }

        // Give the browser a beat to come forward before reading its window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let frame = AccessibilityFinder.textFieldFrame(in: browser, matching: axName) else {
                status("Couldn't find the \(label) field — is a compose window open?", false)
                return
            }
            // Click near the top-left of the field: the middle of an empty
            // body is covered by Gmail's "Help me write" overlay.
            MouseClicker.click(at: NSPoint(x: frame.minX + min(24, frame.width / 2),
                                           y: frame.maxY - min(13, frame.height / 2)))
            status(label, true)
        }
    }
}
