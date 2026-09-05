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
/// against Chrome's web content elsewhere in this app. Open and Toggle sit
/// outside that model: they act on Safari itself rather than on a tab that's
/// assumed to be open already.
@MainActor
enum YouTubeActions {

    /// Where Open lands when no YouTube tab is open anywhere yet.
    private static let homeURL = URL(string: "https://www.youtube.com")!
    private static let safariBundleID = "com.apple.Safari"

    static func perform(_ action: String, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        // Open and Toggle run ahead of the "is a YouTube tab open?" guard
        // below: both act on Safari itself, and Open's whole job is to get
        // there when no tab — or no Safari — exists yet.
        switch action {
        case "OPEN": open(status: status); return
        case "TOGGLE_APP": toggleApp(status: status); return
        default: break
        }
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
            case "VOLUME_UP":
                ActivityLog.recordAction("youtube-volume-up")
                AXActions.press("up")
                status("YouTube — volume up", true)
            case "VOLUME_DOWN":
                ActivityLog.recordAction("youtube-volume-down")
                AXActions.press("down")
                status("YouTube — volume down", true)
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

    /// A single tap on the phone's Open tile. Brings back Safari's YouTube tab
    /// if it already has one — even pinned, in a background tab, or minimized
    /// into the Dock by Collapse — and otherwise opens youtube.com in Safari.
    ///
    /// Safari specifically, not "whichever browser has YouTube" the way the
    /// playback controls work: Open is the tile that decides where YouTube
    /// lives, so it always lands in the same place, and Quit then knows what
    /// to close. Chrome having its own YouTube tab open doesn't hijack it.
    static func open(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("youtube-open")
        // Un-minimizing comes first: neither activate() nor AppleScript's
        // window raise takes a window back out of the Dock on its own.
        if let (app, window) = minimizedSafariYouTubeWindow() {
            setMinimized(false, on: window)
            app.activate(options: [.activateAllWindows])
            status("YouTube — Safari restored", true)
            return
        }
        if BrowserTabReader.selectTab(urlContains: "youtube.com", in: safariBundleID) != nil {
            status("YouTube — brought to the front in Safari", true)
            return
        }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleID) else {
            status("Couldn't find Safari on this Mac.", false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([homeURL], withApplicationAt: safari, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    log.error("opening YouTube in Safari failed: \(error.localizedDescription, privacy: .public)")
                    status("Couldn't open Safari.", false)
                } else {
                    status("YouTube — opened in Safari", true)
                }
            }
        }
    }

    /// A double tap on that same tile, which toggles Safari rather than only
    /// quitting it: Safari up means quit, Safari gone means open it again. The
    /// double tap is the gesture people reach for both ways round, so a second
    /// one has to bring YouTube back rather than answer "nothing to quit".
    ///
    /// `isTerminated` filters out a Safari still winding down from the
    /// previous double tap, which would otherwise absorb this one as a second
    /// quit and leave the tile needing a third tap to reopen.
    static func toggleApp(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        guard let safari = NSRunningApplication
            .runningApplications(withBundleIdentifier: safariBundleID)
            .first(where: { !$0.isTerminated })
        else {
            open(status: status)
            return
        }
        ActivityLog.recordAction("youtube-quit")
        // An ordinary Quit request rather than a kill, so Safari's own window
        // restoring puts the tabs back on the next launch.
        guard safari.terminate() else {
            status("Couldn't quit Safari.", false)
            return
        }
        status("Quit Safari — double-tap again to reopen", true)
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

    /// Safari's minimized window whose title reads like a YouTube page — what
    /// Collapse leaves behind. The title is the only clue available: a
    /// minimized window stops being its app's front window, so the usual
    /// active-tab URL lookup can no longer see it. Narrower than
    /// `anyMinimizedBrowserWindow()`, so Open doesn't restore some unrelated
    /// window that happened to be minimized.
    private static func minimizedSafariYouTubeWindow() -> (NSRunningApplication, AXUIElement)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).first
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = AccessibilityFinder.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]
        else { return nil }
        for window in windows
        where (AccessibilityFinder.attribute(window, kAXMinimizedAttribute) as? Bool) == true {
            let title = (AccessibilityFinder.attribute(window, kAXTitleAttribute) as? String) ?? ""
            if title.localizedCaseInsensitiveContains("youtube") { return (app, window) }
        }
        return nil
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
