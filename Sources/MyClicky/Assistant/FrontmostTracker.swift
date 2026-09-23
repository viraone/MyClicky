import AppKit

/// Panel interaction activates Peeky, but questions and commands still refer
/// to the external app the user was working in. Never use this for focus checks.
@MainActor
final class FrontmostTracker: NSObject {
    static var shared = FrontmostTracker()

    private(set) var lastForeignApp: NSRunningApplication?
    private let notificationCenter: NotificationCenter
    private let frontmostApplication: () -> NSRunningApplication?
    private let ownPID: pid_t
    private let ownBundleIdentifier: String

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.local.MyClicky") {
        self.notificationCenter = notificationCenter
        self.frontmostApplication = frontmostApplication
        self.ownPID = ownPID
        self.ownBundleIdentifier = ownBundleIdentifier
        super.init()
        notificationCenter.addObserver(self, selector: #selector(didActivate(_:)),
                                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        remember(frontmostApplication())
    }

    var targetApplication: NSRunningApplication? {
        guard let app = frontmostApplication(), !app.isTerminated else { return nil }
        if isOwnApplication(app) {
            guard let previous = lastForeignApp, !previous.isTerminated else { return nil }
            return previous
        }
        remember(app)
        return app
    }

    private func isOwnApplication(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ownPID || app.bundleIdentifier == ownBundleIdentifier
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated, !isOwnApplication(app) else { return }
        lastForeignApp = app
    }

    @objc private func didActivate(_ notification: Notification) {
        remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    deinit {
        notificationCenter.removeObserver(self)
    }
}
