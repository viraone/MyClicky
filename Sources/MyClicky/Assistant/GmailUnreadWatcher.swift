import Foundation
import OSLog

/// Watches Gmail's unread count by reading its browser tab title (Gmail
/// encodes it there, e.g. "Inbox (4) - name@gmail.com - Gmail"), and reports
/// changes so the phone can show a badge on the GMAIL mode button — mirrors
/// `WhatsAppUnreadWatcher`, but there's no Dock badge to read since Gmail is
/// just a tab, not a standalone app.
@MainActor
final class GmailUnreadWatcher {
    private static let log = Logger(subsystem: "com.myclicky", category: "gmail")

    /// Called on every change with the new count (0 = no unread, or the tab
    /// isn't currently showing the inbox view).
    var onChange: ((Int) -> Void)?
    private(set) var count = 0

    private var timer: Timer?
    /// A tick is skipped while the previous title read is still in flight,
    /// so a slow browser can't cause overlapping polls.
    private var pollInFlight = false

    /// Scanning every open tab in every browser window is heavier than the
    /// WhatsApp Dock-badge read, so this polls less often.
    func start(interval: TimeInterval = 10) {
        stop()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let new = await Self.unreadCount()
            self.pollInFlight = false
            guard new != self.count else { return }
            Self.log.notice("unread \(self.count) -> \(new)")
            self.count = new
            self.onChange?(new)
        }
    }

    /// The number in the first "(N)" found in Gmail's tab title, or 0 if no
    /// Gmail tab is open, or its title has no unread count in it right now
    /// (e.g. a compose window or an open thread is showing instead of the
    /// inbox list).
    static func unreadCount() async -> Int {
        guard let title = await BrowserTabReader.firstTabTitleAsync(urlContains: "mail.google.com"),
              let open = title.firstIndex(of: "("),
              let close = title[open...].firstIndex(of: ")") else { return 0 }
        return Int(title[title.index(after: open)..<close]) ?? 0
    }
}
