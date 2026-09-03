import AppKit
import ApplicationServices
import OSLog

/// Watches WhatsApp's unread count by reading its Dock icon badge through
/// Accessibility (the Dock exposes it as `AXStatusLabel`), and reports
/// changes so the phone can show a badge — silently, DND or not.
@MainActor
final class WhatsAppUnreadWatcher {
    private static let log = Logger(subsystem: "com.myclicky", category: "whatsapp")

    /// Called on every change with the new count (0 = badge cleared).
    var onChange: ((Int) -> Void)?
    private(set) var count = 0

    private var timer: Timer?

    func start(interval: TimeInterval = 3) {
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
        let new = Self.dockBadge(forAppNamed: "WhatsApp") ?? 0
        guard new != count else { return }
        Self.log.notice("unread \(self.count) -> \(new)")
        count = new
        onChange?(new)
    }

    /// Badge number shown on the Dock tile whose title is `name`, or nil if
    /// there's no badge / the app isn't in the Dock.
    static func dockBadge(forAppNamed name: String) -> Int? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var budget = 0
        return find(in: root, budget: &budget) { element in
            guard let title = attribute(element, kAXTitleAttribute) as? String,
                  title.unicodeScalars.filter({ !$0.properties.isDefaultIgnorableCodePoint }).map(String.init).joined() == name,
                  let url = attribute(element, kAXURLAttribute) as? URL, url.pathExtension == "app"
            else { return nil }
            let label = attribute(element, "AXStatusLabel") as? String ?? ""
            let digits = label.filter(\.isNumber)
            return Int(digits) ?? (label.isEmpty ? 0 : 1)
        }
    }

    private static func find(in element: AXUIElement, budget: inout Int,
                             _ test: (AXUIElement) -> Int?) -> Int? {
        budget += 1
        if budget > 500 { return nil }
        if let hit = test(element) { return hit }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let hit = find(in: child, budget: &budget, test) { return hit }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
