import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "youtube")

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

    /// The same window `BrowserTabReader` means by "front window" — a
    /// multi-window browser (several Chrome windows open) has to minimize/
    /// restore the one actually showing YouTube, not just whichever window
    /// last had keyboard focus. `kAXMainWindowAttribute` tracks that per-app
    /// "front" designation even while the app isn't the active app, unlike
    /// `kAXFocusedWindowAttribute` (keyboard focus, which is what
    /// `AccessibilityFinder.windows(of:)` prefers and can point elsewhere
    /// here since this runs without activating the browser first).
    private static func frontWindow(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let main = AccessibilityFinder.attribute(appElement, kAXMainWindowAttribute) {
            return (main as! AXUIElement)
        }
        return AccessibilityFinder.windows(of: appElement).first
    }

    /// Toggles the Dock-minimized state of the browser window playing
    /// YouTube, via the Accessibility API directly — no keystroke, so it
    /// doesn't need the window focused or the app frontmost first (and
    /// restoring re-activates the app so the video is back in view).
    /// Hands back the resulting state so the phone's button can flip its
    /// own label between "Collapse Browser" and "Expand Browser".
    ///
    /// Expand is checked first and doesn't go through `targetBrowser()`:
    /// once a window is minimized it stops being any browser's "front
    /// window", so the usual "does the front window have a YouTube tab"
    /// lookup can't find it any more to un-minimize it.
    static func toggleCollapse(status: @escaping (_ message: String, _ ok: Bool, _ collapsed: Bool) -> Void) {
        if let (app, window) = anyMinimizedBrowserWindow() {
            ActivityLog.recordAction("youtube-expand")
            guard setMinimized(false, on: window) else {
                status("Couldn't restore the browser window.", false, true)
                return
            }
            app.activate(options: [.activateAllWindows])
            status("YouTube — browser restored", true, false)
            return
        }
        guard let app = targetBrowser(), let window = frontWindow(of: app) else {
            status("No YouTube tab open in your browser.", false, false)
            return
        }
        ActivityLog.recordAction("youtube-collapse")
        guard setMinimized(true, on: window) else {
            status("Couldn't minimize the browser window.", false, false)
            return
        }
        status("YouTube — browser minimized", true, true)
    }

    @discardableResult
    private static func setMinimized(_ minimized: Bool, on window: AXUIElement) -> Bool {
        let title = (AccessibilityFinder.attribute(window, kAXTitleAttribute) as? String) ?? "?"
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                                   minimized ? kCFBooleanTrue : kCFBooleanFalse)
        if result != .success {
            log.error("set minimized=\(minimized) failed (\(result.rawValue)) on window=\(title, privacy: .public)")
        }
        return result == .success
    }

    /// The first minimized window belonging to any of the supported
    /// browsers, if one exists.
    private static func anyMinimizedBrowserWindow() -> (NSRunningApplication, AXUIElement)? {
        for bundleID in BrowserTabReader.supportedBundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = AccessibilityFinder.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            if let minimized = windows.first(where: { (AccessibilityFinder.attribute($0, kAXMinimizedAttribute) as? Bool) == true }) {
                return (app, minimized)
            }
        }
        return nil
    }
}
