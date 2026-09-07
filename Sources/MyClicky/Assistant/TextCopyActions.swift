import AppKit
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "text-copy")

/// Voice-driven text copying: "copy the paragraph that starts with X",
/// "copy from <first words> to <last words>".
///
/// Nothing is selected on screen. Selecting would mean simulating a drag
/// across text whose on-screen geometry we'd have to infer — fragile, and
/// pointless when the text itself is readable directly. So the text is read,
/// the range is resolved, and the result goes on the clipboard.
///
/// Anchors are resolved by Claude rather than by string matching. Spoken
/// anchors arrive mangled — "func handleTap" comes back as "funk handle tap"
/// — so an exact `range(of:)` would miss constantly. Claude gets the real
/// text plus the raw spoken words and returns the passage verbatim.
@MainActor
enum TextCopyActions {

    struct Source {
        let appName: String
        let text: String
    }

    /// The text the person is actually looking at.
    ///
    /// Whatever is frontmost wins. Reaching for the browser first regardless
    /// would mean that saying "copy the paragraph starting with X" while
    /// editing in VS Code silently copies from a Safari tab sitting behind it
    /// — right answer, wrong document, and nothing on screen to say so.
    /// Only when the frontmost app yields nothing readable does it fall back
    /// to a browser that happens to be open.
    static func readVisibleText() -> Source? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsBrowser = frontmost?.bundleIdentifier
            .map(BrowserTabReader.supportedBundleIDs.contains) ?? false

        if frontmostIsBrowser, let source = browserText() { return source }
        if let editor = EditorContextReader.current() {
            return Source(appName: editor.appName, text: capped(editor.text))
        }
        // A focused field in a chat app (Electron, say) is usually an empty
        // composer, not the document the user is looking at. Anything that
        // short loses to a browser tab in the background.
        let focused = frontmost.flatMap(focusedText(of:))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if focused.count >= 40, let frontmost {
            return Source(appName: frontmost.localizedName ?? "that app", text: capped(focused))
        }
        if let browser = browserText() { return browser }
        if !focused.isEmpty, let frontmost {
            return Source(appName: frontmost.localizedName ?? "that app", text: capped(focused))
        }
        return nil
    }

    private static func browserText() -> Source? {
        guard let browser = BrowserTabReader.runningBrowser(withTabMatching: { _ in true }),
              let text = BrowserTabReader.runJavaScript("document.body.innerText", inTabMatching: { _ in true }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return Source(appName: browser.localizedName ?? "the browser", text: capped(text))
    }

    private static let maxLength = 60_000

    private static func capped(_ text: String) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) + "\n…(truncated)" : text
    }

    private static func focusedText(of app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = AccessibilityFinder.attribute(axApp, kAXFocusedUIElementAttribute) else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        return (AccessibilityFinder.attribute(element, kAXSelectedTextAttribute) as? String)
            ?? (AccessibilityFinder.attribute(element, kAXValueAttribute) as? String)
    }

    // MARK: - The two shapes of request

    /// "Copy the paragraph that starts with X" — one anchor, Claude decides
    /// where the paragraph ends.
    static func copyParagraph(startingWith anchor: String, claude: AnthropicService) async -> Result {
        await copy(request: "Copy the single paragraph or block that begins with: \"\(anchor)\". "
                          + "Return that whole paragraph or block, from its first character to its last.",
                   claude: claude)
    }

    /// "Copy from X to Y" — two anchors bounding a range, inclusive of both.
    static func copyRange(from start: String, to end: String, claude: AnthropicService) async -> Result {
        await copy(request: "Copy the passage that starts at \"\(start)\" and ends at \"\(end)\". "
                          + "Include both the starting and the ending text in what you return.",
                   claude: claude)
    }

    enum Result {
        case copied(text: String, from: String, verbatim: Bool)
        case noSource
        case notFound(String)
        case failed(String)
    }

    private static let system = """
    You extract an exact passage from a document for someone copying it to \
    their clipboard by voice.

    You get the document's real text and the words the person spoke to \
    describe where the passage starts and ends. Those spoken words came from \
    speech-to-text and are often wrong in predictable ways: "func" becomes \
    "funk", identifiers get split into separate words, punctuation and \
    casing are missing entirely. Match them to the document by what the \
    person clearly meant, not by exact characters.

    Return the passage exactly as it appears in the document — character for \
    character, including original indentation, line breaks, casing and \
    punctuation. Do not reformat it, do not fix it, do not summarise it, do \
    not add a code fence or any commentary. It is going straight onto a \
    clipboard and will be pasted somewhere else as-is.

    Reply with JSON only: {"found": true, "text": "<the passage verbatim>"} \
    or, when nothing in the document plausibly matches, \
    {"found": false, "reason": "<short reason>"}. Never answer in prose — \
    if you can't find it, say so inside the JSON.
    """

    private static func copy(request: String, claude: AnthropicService) async -> Result {
        guard let source = readVisibleText() else { return .noSource }

        let payload = """
        \(request)

        <document app="\(source.appName)">
        \(source.text)
        </document>
        """
        do {
            let json = try await claude.requestJSON(
                system: system,
                userText: payload,
                // The passage itself is the answer, so the ceiling has to fit
                // a long block of code, not just a sentence.
                maxTokens: 16_000,
                timeout: 120
            )
            guard json["found"] as? Bool == true, let text = json["text"] as? String, !text.isEmpty else {
                let reason = json["reason"] as? String ?? "Couldn't find that in what's on screen."
                ActivityLog.recordAction("copy-text-miss", ["reason": reason])
                return .notFound(reason)
            }
            // Whether it really came from the document, ignoring whitespace
            // differences. A false here means Claude reconstructed rather than
            // quoted, which is worth saying out loud before it gets sent
            // somewhere.
            let verbatim = squashed(source.text).contains(squashed(text))
            if !verbatim {
                log.notice("copied passage is not a verbatim substring of the source")
            }
            put(text, onClipboard: true)
            // Logged so a test that goes sideways can be told apart from one
            // that never ran — the character count, never the text itself,
            // which is whatever happened to be on screen.
            ActivityLog.recordAction("copy-text", [
                "chars": "\(text.count)",
                "source": source.appName,
                "verbatim": verbatim ? "yes" : "no",
            ])
            return .copied(text: text, from: source.appName, verbatim: verbatim)
        } catch AnthropicService.ServiceError.notJSON(let prose) where !prose.isEmpty {
            // Prose in place of JSON is the model saying it couldn't find
            // the passage — relay that rather than a parsing complaint.
            let reason = prose.count <= 240 ? prose : "Couldn't find that in what's on screen."
            ActivityLog.recordAction("copy-text-miss", ["reason": reason])
            return .notFound(reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func squashed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Puts the passage on the system clipboard so ⌘V works normally. The
    /// copy Peeky remembers is held separately by the controller — the
    /// system clipboard is shared with everything else on the Mac and can be
    /// overwritten a second later.
    static func put(_ text: String, onClipboard: Bool) {
        guard onClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
