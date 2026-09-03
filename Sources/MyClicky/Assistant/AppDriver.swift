import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "appdriver")

/// Generic app lifecycle helpers: resolve a human app name to a bundle ID,
/// launch/find a running instance, and bring its window(s) to the front.
/// Extracted from `WhatsAppActions` so any app — not just WhatsApp — can be
/// driven the same way.
enum AppDriver {

    /// Resolves a display name ("Mail", "Messages", "Safari") to its bundle ID
    /// and app URL. `fullPath(forApplication:)` is deprecated but remains the
    /// simplest name→path lookup NSWorkspace offers; everything downstream
    /// keys off the bundle ID it hands back, not the name.
    static func resolve(appNamed name: String) -> (bundleID: String, url: URL)? {
        guard let path = NSWorkspace.shared.fullPath(forApplication: name),
              let bundle = Bundle(path: path),
              let bundleID = bundle.bundleIdentifier else { return nil }
        return (bundleID, URL(fileURLWithPath: path))
    }

    /// The running instance for a bundle ID, launching it if necessary and
    /// waiting briefly for it to appear.
    @MainActor
    static func ensureRunning(bundleID: String) -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<20 {
            usleep(100_000)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return running
            }
        }
        return nil
    }

    /// Resolves `name` and ensures it's running, in one call. Matches an
    /// already-running app by localized name first (cheap, and correct even
    /// if `resolve` can't find an installed copy on disk).
    @MainActor
    static func ensureRunning(appNamed name: String) -> NSRunningApplication? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return running
        }
        guard let (bundleID, _) = resolve(appNamed: name) else { return nil }
        return ensureRunning(bundleID: bundleID)
    }

    /// Makes `app`'s window(s) visible and frontmost: unhides the app,
    /// un-minimizes any window parked in the Dock, and — if it has no window
    /// at all (closed with the red button) — asks it to reopen, like clicking
    /// its Dock icon. Plain `activate` does none of that.
    @MainActor
    static func bringForward(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        let windows = windowsValue as? [AXUIElement] ?? []
        var restored = false
        for window in windows {
            var minimized: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                restored = true
            }
        }
        if windows.isEmpty, let bundleID = app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // No window at all: a relaunch request on a running app is a "reopen".
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            restored = true
        }
        let activated = app.activate(options: [.activateAllWindows])
        log.notice("bringForward \(app.localizedName ?? "?", privacy: .public) windows=\(windows.count) restored=\(restored) activated=\(activated)")
        if restored { usleep(500_000) }
    }
}
