import AppKit
import ApplicationServices
import OSLog

private let claudeTalkLog = Logger(subsystem: "com.local.MyClicky", category: "ClaudeTalk")

/// The phone's TALK key: presses the microphone button in the Claude desktop
/// app, so the user can talk to Claude from the phone.
///
/// The mic is an AXCheckBox whose description is exactly "Press and hold to
/// record". It is matched only on AXDescription — never title — because
/// sidebar session titles can contain words like "voice" or "record".
@MainActor
enum ClaudeDesktopTalk {
    /// One microphone button found in Claude's window.
    struct MicCandidate: Equatable {
        var label: String
        /// AppKit screen coordinates (origin bottom-left).
        var frame: NSRect
    }

    /// Debug switch for testing the real path without pressing anything:
    /// `defaults write com.local.MyClicky ClaudeTalkDryRun -bool true`.
    private static var dryRun: Bool { UserDefaults.standard.bool(forKey: "ClaudeTalkDryRun") }

    // MARK: - Pure helpers (unit tested)

    /// Whether an accessibility description is Claude's microphone button.
    /// Matched only on description, never title, so sidebar session titles
    /// like "voice notes" or "recordings" can't be picked up.
    nonisolated static func isMicDescription(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("hold to record")
            || lower.contains("stop recording")
            || lower.contains("start recording")
            || lower.contains("dictat")
    }

    /// The microphone button to press: the lowest one on screen (smallest
    /// minY, AppKit origin bottom-left), ties broken by largest midX.
    nonisolated static func pickMicButton(_ candidates: [MicCandidate]) -> MicCandidate? {
        let mics = candidates.filter { isMicDescription($0.label) }
        guard !mics.isEmpty else { return nil }
        return mics.min { a, b in
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            return a.frame.midX > b.frame.midX
        }
    }

    // MARK: - The whole run

    static func run() async -> ClaudeDesktopPaste.Result {
        guard AXIsProcessTrusted() else {
            return fail("Allow Accessibility for Peeky on the Mac to use TALK")
        }
        guard let app = runningClaude() else {
            return fail("Open the Claude desktop app on the Mac first")
        }

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
        restoreIfMinimized(appElement)

        guard let (element, candidate) = await waitFor(seconds: 8, { micButton(in: appElement) }) else {
            return fail("Couldn't find Claude's microphone button — open a chat in Claude first")
        }

        if dryRun {
            return ClaudeDesktopPaste.Result(ok: true, message: "Dry run: found Claude's microphone button, did not press it")
        }

        let before = AccessibilityFinder.attribute(element, kAXValueAttribute) as? Int
        let press = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if press != .success {
            MouseClicker.click(at: NSPoint(x: candidate.frame.midX, y: candidate.frame.midY))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let after = AccessibilityFinder.attribute(element, kAXValueAttribute) as? Int

        let message: String
        if after == 1 {
            message = "Claude is listening — talk now, tap TALK again to stop"
        } else if after == 0, before == 1 {
            message = "Stopped listening"
        } else {
            message = "Pressed Claude's microphone button"
        }
        return ClaudeDesktopPaste.Result(ok: true, message: message)
    }

    // MARK: - Pieces

    private static func fail(_ message: String) -> ClaudeDesktopPaste.Result {
        claudeTalkLog.notice("claude talk: \(message, privacy: .public)")
        return ClaudeDesktopPaste.Result(ok: false, message: message)
    }

    private static func runningClaude() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopPaste.bundleID).first
    }

    private static func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopPaste.bundleID
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

    /// Claude's microphone button, from the first window that has one.
    private static func micButton(in appElement: AXUIElement) -> (AXUIElement, MicCandidate)? {
        for window in AccessibilityFinder.windows(of: appElement) {
            var candidates: [(AXUIElement, MicCandidate)] = []
            var visited = 0
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                guard let role = AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String,
                      role == kAXCheckBoxRole || role == kAXButtonRole,
                      let description = AccessibilityFinder.attribute(element, kAXDescriptionAttribute) as? String,
                      isMicDescription(description),
                      let frame = AccessibilityFinder.frame(of: element) else { return false }
                candidates.append((element, MicCandidate(label: description, frame: frame)))
                return false
            }
            if let best = pickMicButton(candidates.map { $0.1 }),
               let match = candidates.first(where: { $0.1 == best }) {
                return match
            }
        }
        return nil
    }
}

