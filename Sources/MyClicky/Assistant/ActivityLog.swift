import AppKit

/// Append-only local activity log powering the ClickyLogs dashboard.
/// Events are written as JSON lines to
/// ~/Library/Application Support/MyClicky/ClickyLogs/events-YYYY-MM-DD.jsonl
/// Data never leaves this Mac.
@MainActor
enum ActivityLog {
    private static var sampleTimer: Timer?
    private static var lastSampleKey: String?

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    static var logDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyClicky/ClickyLogs", isDirectory: true)
    }

    /// Records one event. `details` values are short strings (question text,
    /// URL, app name, file name…).
    static func record(_ type: String, _ details: [String: String] = [:]) {
        var payload: [String: String] = details
        payload["type"] = type
        payload["ts"] = ISO8601DateFormatter().string(from: Date())

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let dir = logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let file = dir.appendingPathComponent("events-\(day.string(from: Date())).jsonl")

        var line = data
        line.append(0x0A) // newline
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// Records a Clicky action (ask, dictate, capture, click, trash) and
    /// automatically attaches the frontmost app and, when a browser is open,
    /// the site the user was on when they used Clicky.
    static func recordAction(_ type: String, _ details: [String: String] = [:]) {
        var payload = details
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            payload["app"] = app
        }
        if let url = BrowserTabReader.activeTabURL() {
            payload["url"] = url
        }
        record(type, payload)
    }

    /// Samples the frontmost app (and the active site when a browser is
    /// frontmost) every 60 seconds, so the dashboard can show top sites and
    /// top apps for the week. Consecutive identical samples are skipped.
    static func startSampling() {
        guard sampleTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in takeSample() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        takeSample()
    }

    private static func takeSample() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        var details: [String: String] = ["app": app.localizedName ?? app.bundleIdentifier ?? "Unknown"]
        if let bundleID = app.bundleIdentifier, browserBundleIDs.contains(bundleID),
           let url = BrowserTabReader.activeTabURL() {
            details["url"] = url
        }
        // Skip repeats so idle time on one screen doesn't flood the log,
        // but still counts once per minute for "time spent" stats.
        let key = "\(details["app"] ?? "")|\(details["url"] ?? "")"
        details["repeat"] = key == lastSampleKey ? "1" : "0"
        lastSampleKey = key
        record("sample", details)
    }
}
