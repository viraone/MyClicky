import AppKit
import ApplicationServices

/// YouTube playback controls driven from the phone's YOUTUBE tab. Targets
/// whichever running browser (Chrome/Safari/Arc/Edge/Brave) has an active
/// YouTube tab, brings it forward, and sends the same keyboard shortcuts
/// YouTube's own player already responds to — no extension, no JavaScript
/// permission needed. Like/Subscribe have no keyboard shortcut, so those go
/// through the Accessibility API instead — the same path already proven
/// against Chrome's web content elsewhere in this app.
@MainActor
enum YouTubeActions {

    static func perform(_ action: String, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        guard let app = targetBrowser() else {
            status("No YouTube tab open in your browser.", false)
            return
        }
        // Minimizing shouldn't bring the browser forward first — that would
        // flash it to front right before it disappears into the Dock.
        if action == "COLLAPSE" {
            ActivityLog.recordAction("youtube-collapse")
            if minimizeFrontWindow(of: app) {
                status("YouTube — browser minimized", true)
            } else {
                status("Couldn't minimize the browser window.", false)
            }
            return
        }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            switch action {
            case "PLAYPAUSE":
                ActivityLog.recordAction("youtube-playpause")
                AXActions.press("k")
                status("YouTube — play/pause", true)
            case "SKIP_FORWARD":
                ActivityLog.recordAction("youtube-skip-forward")
                AXActions.press("l")
                status("YouTube — +10s", true)
            case "SKIP_BACK":
                ActivityLog.recordAction("youtube-skip-back")
                AXActions.press("j")
                status("YouTube — -10s", true)
            case "FULLSCREEN":
                ActivityLog.recordAction("youtube-fullscreen")
                AXActions.press("f")
                status("YouTube — fullscreen toggled", true)
            case "MUTE":
                ActivityLog.recordAction("youtube-mute")
                AXActions.press("m")
                status("YouTube — mute toggled", true)
            case "LIKE":
                ActivityLog.recordAction("youtube-like")
                if AXActions.click(label: "like this video", in: app) {
                    status("YouTube — liked", true)
                } else {
                    status("Couldn't find the Like button — is a video open?", false)
                }
            case "SUBSCRIBE":
                ActivityLog.recordAction("youtube-subscribe")
                // Exact match on "Subscribe" only — the button reads
                // "Unsubscribe" once already subscribed, and a loose
                // substring match would toggle it back off instead of
                // leaving it alone.
                if let frame = AccessibilityFinder.elementFrame(
                    in: app, roles: [kAXButtonRole], matching: "Subscribe", exact: true, onScreenOnly: true
                ) {
                    MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
                    status("YouTube — subscribed", true)
                } else {
                    status("Already subscribed, or no channel page open.", false)
                }
            default:
                break
            }
        }
    }

    /// The running browser whose active tab is a YouTube page.
    private static func targetBrowser() -> NSRunningApplication? {
        BrowserTabReader.runningBrowser(withTabMatching: { $0.contains("youtube.com") || $0.contains("youtu.be/") })
    }

    /// Minimizes the browser's frontmost window to the Dock via the
    /// Accessibility API directly — no keystroke, so it doesn't need the
    /// window focused or the app frontmost first.
    private static func minimizeFrontWindow(of app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AccessibilityFinder.windows(of: appElement).first else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }
}
