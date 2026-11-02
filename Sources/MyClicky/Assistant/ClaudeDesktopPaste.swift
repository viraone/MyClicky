import AppKit
import ApplicationServices
import OSLog

private let claudePasteLog = Logger(subsystem: "com.local.MyClicky", category: "ClaudePaste")

/// The phone's CLAUDE PASTE key: takes the image on the Mac clipboard (left
/// there by CAPTURE or ENTIRE SCREEN), puts it in the Claude desktop app's
/// chat box and sends it.
///
/// Every step is checked before the next one runs, and the keystrokes only go
/// out while Claude really is the frontmost app, so a Return is never typed
/// into whatever else happened to be on screen.
@MainActor
enum ClaudeDesktopPaste {
    static let bundleID = "com.anthropic.claudefordesktop"

    struct Result: Equatable {
        let ok: Bool
        let message: String
    }

    /// One text area found in Claude's window.
    struct PromptCandidate: Equatable {
        var label: String
        /// AppKit screen coordinates (origin bottom-left).
        var frame: NSRect
        /// Whether the box already has the keyboard. Then the paste goes
        /// straight in, and a click would only move the user's cursor.
        var isFocused = false
    }

    private static var inFlight = false

    /// Debug switch for testing the real path without sending anything into a
    /// chat: `defaults write com.local.MyClicky ClaudePasteDryRun -bool true`.
    /// The image is pasted and then removed again instead of sent.
    private static var dryRun: Bool { UserDefaults.standard.bool(forKey: "ClaudePasteDryRun") }

    // MARK: - Pure helpers (unit tested)

    /// Claude labels its chat box "Prompt" while a reply is streaming and
    /// "Write your prompt to Claude" when idle, so the match is on the word
    /// "prompt". Failing that, the chat box is the lowest text area in the
    /// window; a search box or the like sits above it.
    nonisolated static func pickPromptBox(_ candidates: [PromptCandidate]) -> PromptCandidate? {
        let labelled = candidates.filter { $0.label.lowercased().contains("prompt") }
        let pool = labelled.isEmpty ? candidates : labelled
        return pool.min { $0.frame.minY < $1.frame.minY }
    }

    /// Whether the clipboard holds a picture that can be pasted as an image.
    /// CAPTURE writes PNG and TIFF (plus dictated text when there is any);
    /// ENTIRE SCREEN writes PNG alone.
    nonisolated static func clipboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.png) || types.contains(.tiff)
    }

    /// Whether an accessibility description is Claude's "Remove <picture>"
    /// button, which appears on a draft once a pasted picture has landed.
    nonisolated static func isAttachmentRemoveButton(description: String) -> Bool {
        description.hasPrefix("Remove ")
    }

    // MARK: - The whole run

    static func run() async -> Result {
        guard !inFlight else {
            return fail("Already pasting into Claude — give it a moment")
        }
        inFlight = true
        defer { inFlight = false }

        guard AXIsProcessTrusted() else {
            return fail("Allow Accessibility for Peeky on the Mac to paste into Claude")
        }
        guard clipboardHasImage() else {
            return fail("No image on the Mac clipboard — tap CAPTURE or ENTIRE SCREEN first")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return fail("The Claude desktop app isn't installed on the Mac")
        }

        // Bring Claude up, starting it if it isn't running or has no window.
        var coldStart = false
        var app = runningClaude()
        if app == nil {
            coldStart = true
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            app = await waitFor(seconds: 20) { runningClaude() }
        }
        guard let app else { return fail("Couldn't open the Claude desktop app") }

        app.unhide()
        app.activate(options: [.activateAllWindows])
        guard await waitFor(seconds: 4, { isFrontmost() ? true : nil }) != nil else {
            return fail("Claude wouldn't come to the front")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps only publish their web content once an assistive
        // client asks, and fill the tree in over the next moments.
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if AccessibilityFinder.windows(of: appElement).isEmpty {
            // Running with every window closed: reopening makes a new one.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        restoreIfMinimized(appElement)

        let boxTimeout: Double = coldStart ? 20 : 8
        guard let box = await waitFor(seconds: boxTimeout, { promptBox(in: appElement) }) else {
            return fail("Couldn't find Claude's chat box — open a chat in Claude first")
        }

        let attachedBefore = attachmentCount(in: appElement)

        // Click into the box so the paste lands there whatever had focus —
        // unless the cursor is already in it, which a click would only move.
        if !box.isFocused {
            MouseClicker.click(at: NSPoint(x: box.frame.midX, y: box.frame.midY))
            try? await Task.sleep(for: .milliseconds(300))
        }

        guard isFrontmost() else {
            return fail("Claude lost focus before the paste — nothing sent")
        }
        KeyboardTyper.press(KeyboardTyper.vKey, flags: .maskCommand)

        let attached = await waitFor(seconds: 5) {
            attachmentCount(in: appElement) > attachedBefore ? true : nil
        }
        guard attached != nil else {
            claudePasteLog.notice("image never showed up as an attachment")
            return fail("The image didn't attach in Claude — nothing was sent")
        }
        // Let Claude finish generating the thumbnail before sending.
        try? await Task.sleep(for: .milliseconds(400))

        if dryRun {
            removeAttachments(beyond: attachedBefore, in: appElement)
            return Result(ok: true, message: "Dry run: pasted the image into Claude, then took it back out")
        }

        guard isFrontmost() else {
            return fail("Claude lost focus after the paste — the image is in its chat box, not sent")
        }
        KeyboardTyper.press(KeyboardTyper.returnKey)

        // The draft empties when the message goes. A Return that arrives
        // while Claude is still busy with the paste is dropped, so press once
        // more if the picture is still sitting there; on an empty box a
        // second Return does nothing.
        var sent = await waitFor(seconds: 1.5) {
            attachmentCount(in: appElement) <= attachedBefore ? true : nil
        } != nil
        if !sent, isFrontmost() {
            KeyboardTyper.press(KeyboardTyper.returnKey)
            sent = await waitFor(seconds: 2.5) {
                attachmentCount(in: appElement) <= attachedBefore ? true : nil
            } != nil
        }
        guard sent else {
            return fail("The image is in Claude's chat box but Return didn't send it")
        }

        ActivityLog.recordAction("claude-paste", ["coldStart": coldStart ? "yes" : "no"])
        return Result(ok: true, message: "Image sent to Claude")
    }

    // MARK: - Pieces

    private static func fail(_ message: String) -> Result {
        claudePasteLog.notice("claude paste: \(message, privacy: .public)")
        return Result(ok: false, message: message)
    }

    private static func runningClaude() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Polls `check` every quarter second until it returns a value or the
    /// time runs out.
    private static func waitFor<T>(seconds: Double, _ check: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = check() { return value }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func restoreIfMinimized(_ appElement: AXUIElement) {
        for window in AccessibilityFinder.windows(of: appElement) {
            if (AccessibilityFinder.attribute(window, kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
    }

    /// Claude's chat box, from the first window that has any text area.
    private static func promptBox(in appElement: AXUIElement) -> PromptCandidate? {
        for window in AccessibilityFinder.windows(of: appElement) {
            let windowFrame = AccessibilityFinder.frame(of: window)
            var candidates: [PromptCandidate] = []
            var visited = 0
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                guard AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
                      let frame = AccessibilityFinder.frame(of: element) else { return false }
                if let windowFrame,
                   !windowFrame.insetBy(dx: 2, dy: 2).contains(NSPoint(x: frame.midX, y: frame.midY)) {
                    return false
                }
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { AccessibilityFinder.attribute(element, $0) as? String }
                    .joined(separator: " ")
                let focused = (AccessibilityFinder.attribute(element, kAXFocusedAttribute) as? Bool) == true
                candidates.append(PromptCandidate(label: label, frame: frame, isFocused: focused))
                return false
            }
            if let best = pickPromptBox(candidates) { return best }
        }
        return nil
    }

    /// Presses the "Remove" buttons of pictures added after `baseline`, newest first.
    private static func removeAttachments(beyond baseline: Int, in appElement: AXUIElement) {
        var buttons: [AXUIElement] = []
        for window in AccessibilityFinder.windows(of: appElement) {
            var visited = 0
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                if AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
                   let description = AccessibilityFinder.attribute(element, kAXDescriptionAttribute) as? String,
                   isAttachmentRemoveButton(description: description) {
                    buttons.append(element)
                }
                return false
            }
            if !buttons.isEmpty { break }
        }
        for button in buttons.reversed().prefix(max(0, buttons.count - baseline)) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// How many "Remove <picture>" buttons the window shows: one per image
    /// waiting in the draft.
    private static func attachmentCount(in appElement: AXUIElement) -> Int {
        var count = 0
        for window in AccessibilityFinder.windows(of: appElement) {
            var visited = 0
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                if AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
                   let description = AccessibilityFinder.attribute(element, kAXDescriptionAttribute) as? String,
                   isAttachmentRemoveButton(description: description) {
                    count += 1
                }
                return false
            }
            if count > 0 { break }
        }
        return count
    }
}
