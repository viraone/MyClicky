import AppKit

/// Append-only local activity log powering the ClickyLogs dashboard.
/// Events are written as JSON lines to
/// ~/Library/Application Support/MyClicky/ClickyLogs/events-YYYY-MM-DD.jsonl
/// Data never leaves this Mac.
@MainActor
enum ActivityLog {
    private static var sampleTimer: Timer?
    private static var lastSampleKey: String?

    /// Daily log files older than this are deleted as new ones are written.
    /// The ClickyLogs dashboard only ever looks at the trailing 7 days, so
    /// keeping a month around is already generous headroom.
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Prune runs at most once per launch (further gated to once per day
    /// below), so day-old data isn't rescanned on every single event.
    private static var lastPruneDay: String?

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    static var logDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyClicky/ClickyLogs", isDirectory: true)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Records one event. `details` values are short strings (question text,
    /// URL, app name, file name…).
    static func record(_ type: String, _ details: [String: String] = [:]) {
        var payload: [String: String] = details
        payload["type"] = type
        payload["ts"] = ISO8601DateFormatter().string(from: Date())

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let dir = logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let today = dayFormatter.string(from: Date())
        let file = dir.appendingPathComponent("events-\(today).jsonl")

        var line = data
        line.append(0x0A) // newline
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }

        pruneOldLogsIfNeeded(dir: dir, today: today)
    }

    /// Deletes `events-*.jsonl` files older than `retention`. Cheap to call
    /// often since it no-ops after the first run each day, but still called
    /// from `record` (rather than only from `startSampling`) so logging-only
    /// runs — tests, or a build with sampling disabled — still get swept.
    private static func pruneOldLogsIfNeeded(dir: URL, today: String) {
        guard lastPruneDay != today else { return }
        lastPruneDay = today

        let cutoff = Date().addingTimeInterval(-retention)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("events-"), name.hasSuffix(".jsonl") else { continue }
            let dayString = String(name.dropFirst("events-".count).dropLast(".jsonl".count))
            guard let day = dayFormatter.date(from: dayString), day < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Records a Peeky action (ask, dictate, capture, click, trash) and
    /// automatically attaches the frontmost app and, when a browser is open,
    /// the site the user was on when they used Peeky.
    static func recordAction(_ type: String, _ details: [String: String] = [:]) {
        var payload = details
        if let app = FrontmostTracker.shared.targetApplication?.localizedName {
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
