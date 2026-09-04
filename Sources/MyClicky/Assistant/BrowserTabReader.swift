import AppKit

/// Reads the URL of the active tab in the frontmost supported browser via
/// Apple Events (requires the Automation permission, prompted on first use).
@MainActor
enum BrowserTabReader {
    private struct Browser {
        let bundleID: String
        let script: String
        /// AppleScript that navigates the active tab; `%@` is replaced by the URL.
        var setScript: String? = nil
        /// AppleScript returning the active tab's page title.
        var titleScript: String? = nil
        /// AppleScript that reloads the active tab.
        var reloadScript: String? = nil
        /// AppleScript that runs JavaScript in the active tab; `%@` is replaced
        /// by the (AppleScript-escaped) source and the result is returned.
        var jsScript: String? = nil
    }

    private static let browsers: [Browser] = [
        Browser(
            bundleID: "com.google.Chrome",
            script: #"tell application "Google Chrome" to return URL of active tab of front window"#,
            setScript: #"tell application "Google Chrome" to set URL of active tab of front window to "%@""#,
            titleScript: #"tell application "Google Chrome" to return name of active tab of front window"#,
            reloadScript: #"tell application "Google Chrome" to reload active tab of front window"#,
            jsScript: #"tell application "Google Chrome" to execute active tab of front window javascript "%@""#
        ),
        Browser(
            bundleID: "com.apple.Safari",
            script: #"tell application "Safari" to return URL of front document"#,
            setScript: #"tell application "Safari" to set URL of front document to "%@""#,
            titleScript: #"tell application "Safari" to return name of front document"#,
            reloadScript: #"tell application "Safari" to set URL of front document to (URL of front document)"#,
            jsScript: #"tell application "Safari" to do JavaScript "%@" in front document"#
        ),
        Browser(
            bundleID: "company.thebrowser.Browser", // Arc
            script: #"tell application "Arc" to return URL of active tab of front window"#,
            setScript: #"tell application "Arc" to set URL of active tab of front window to "%@""#,
            titleScript: #"tell application "Arc" to return name of active tab of front window"#,
            reloadScript: #"tell application "Arc" to reload active tab of front window"#,
            jsScript: #"tell application "Arc" to execute active tab of front window javascript "%@""#
        ),
        Browser(
            bundleID: "com.microsoft.edgemac",
            script: #"tell application "Microsoft Edge" to return URL of active tab of front window"#,
            setScript: #"tell application "Microsoft Edge" to set URL of active tab of front window to "%@""#,
            titleScript: #"tell application "Microsoft Edge" to return name of active tab of front window"#,
            reloadScript: #"tell application "Microsoft Edge" to reload active tab of front window"#,
            jsScript: #"tell application "Microsoft Edge" to execute active tab of front window javascript "%@""#
        ),
        Browser(
            bundleID: "com.brave.Browser",
            script: #"tell application "Brave Browser" to return URL of active tab of front window"#,
            setScript: #"tell application "Brave Browser" to set URL of active tab of front window to "%@""#,
            titleScript: #"tell application "Brave Browser" to return name of active tab of front window"#,
            reloadScript: #"tell application "Brave Browser" to reload active tab of front window"#,
            jsScript: #"tell application "Brave Browser" to execute active tab of front window javascript "%@""#
        ),
    ]

    /// Bundle IDs of every browser this reads tabs from, for callers that
    /// need to search across all of them directly rather than just asking
    /// "which one has this tab in its front window" (e.g. finding a window
    /// that's currently minimized, which stops counting as any browser's
    /// front window).
    static let supportedBundleIDs: [String] = browsers.map(\.bundleID)

    static func activeTabURL() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Prefer the frontmost browser, then any running one.
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        for browser in ordered where running.contains(browser.bundleID) {
            if let url = run(script: browser.script), !url.isEmpty {
                return url
            }
        }
        return nil
    }

    /// URL and page title of the active tab in the frontmost supported browser.
    static func activeTab() -> (url: String, title: String)? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        for browser in ordered where running.contains(browser.bundleID) {
            if let url = run(script: browser.script), !url.isEmpty {
                let title = browser.titleScript.flatMap { run(script: $0) } ?? ""
                return (url, title)
            }
        }
        return nil
    }

    /// Reloads the active tab of the frontmost (or any running) browser,
    /// like pressing ⌘R. Returns false if no supported browser is running.
    static func reloadActiveTab() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        for browser in ordered where running.contains(browser.bundleID) {
            guard let reloadScript = browser.reloadScript else { continue }
            var error: NSDictionary?
            NSAppleScript(source: reloadScript)?.executeAndReturnError(&error)
            if error == nil { return true }
        }
        return false
    }

    /// Navigates the active tab of the frontmost (or any running) browser whose
    /// current URL matches `predicate`. Returns true if a tab was retargeted.
    static func navigateActiveTab(matching predicate: (String) -> Bool, to url: String) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        for browser in ordered where running.contains(browser.bundleID) {
            guard let setScript = browser.setScript,
                  let current = run(script: browser.script), predicate(current) else { continue }
            let source = setScript.replacingOccurrences(of: "%@", with: url)
            _ = run(script: source)
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
                .first?.activate()
            return true
        }
        return false
    }

    /// Runs JavaScript in the active tab of the frontmost (or any running)
    /// browser whose current URL matches `predicate`, returning the script's
    /// string result. Returns nil if no tab matched or the browser refused
    /// (Chrome needs View ▸ Developer ▸ "Allow JavaScript from Apple Events";
    /// Safari needs Develop ▸ "Allow JavaScript from Apple Events").
    static func runJavaScript(_ js: String, inTabMatching predicate: (String) -> Bool) -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        for browser in ordered where running.contains(browser.bundleID) {
            guard let jsScript = browser.jsScript,
                  let current = run(script: browser.script), predicate(current) else { continue }
            return run(script: jsScript.replacingOccurrences(of: "%@", with: escaped))
        }
        return nil
    }

    /// The frontmost (or any running) supported browser whose active tab URL
    /// matches `predicate`.
    static func runningBrowser(withTabMatching predicate: (String) -> Bool) -> NSRunningApplication? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = browsers.sorted { a, _ in a.bundleID == frontmost }
        for browser in ordered where running.contains(browser.bundleID) {
            guard let current = run(script: browser.script), predicate(current) else { continue }
            return NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first
        }
        return nil
    }

    private static func run(script source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
