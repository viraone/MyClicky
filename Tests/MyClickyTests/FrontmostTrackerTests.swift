import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class FrontmostTrackerTests: XCTestCase {
    private final class App: NSRunningApplication, @unchecked Sendable {
        let pid: pid_t
        let bundle: String
        var hasTerminated = false
        var pidReads = 0
        var activeForTest = false
        var activationSucceeds = true
        var activationCalls = 0

        init(_ pid: pid_t, _ bundle: String) {
            self.pid = pid
            self.bundle = bundle
            super.init()
        }

        override var processIdentifier: pid_t { pidReads += 1; return pid }
        override var bundleIdentifier: String? { bundle }
        override var localizedName: String? { bundle }
        override var isTerminated: Bool { hasTerminated }
        override var isActive: Bool { activeForTest }

        override func activate(options: NSApplication.ActivationOptions = []) -> Bool {
            activationCalls += 1
            activeForTest = activationSucceeds
            return activationSucceeds
        }
    }

    private let own = App(-100, "com.local.MyClicky")
    private let editor = App(-101, "com.microsoft.VSCode")
    private let browser = App(-102, "com.apple.Safari")

    private func activate(_ app: NSRunningApplication, in center: NotificationCenter) {
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: app])
    }

    func testLaunchSnapshotAndPanelActivationKeepExternalTarget() {
        var front: NSRunningApplication? = editor
        let center = NotificationCenter()
        let tracker = FrontmostTracker(notificationCenter: center, frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        XCTAssertTrue(tracker.lastForeignApp === editor)
        XCTAssertTrue(tracker.targetApplication === editor, "hotkey in another app keeps that target")
        front = own
        activate(own, in: center)
        XCTAssertTrue(tracker.targetApplication === editor, "panel mic and typed commands keep the external target")
        XCTAssertTrue(front === own, "resolving a target must never activate it")
    }

    func testWorkspaceNotificationsFollowNewForeignAppAndIgnoreOwnCopies() {
        var front: NSRunningApplication? = editor
        let center = NotificationCenter()
        let tracker = FrontmostTracker(notificationCenter: center, frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        activate(browser, in: center)
        front = own
        activate(own, in: center)
        activate(App(-103, own.bundle), in: center)
        XCTAssertTrue(tracker.lastForeignApp === browser)
        XCTAssertTrue(tracker.targetApplication === browser)
    }

    func testCurrentForeignAppWinsEvenBeforeItsNotificationArrives() {
        var front: NSRunningApplication? = editor
        let tracker = FrontmostTracker(notificationCenter: NotificationCenter(), frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        front = browser
        XCTAssertTrue(tracker.targetApplication === browser)
        front = own
        XCTAssertTrue(tracker.targetApplication === browser)
    }

    func testNoTargetIsInventedForUnknownOrTerminatedApp() {
        var front: NSRunningApplication? = own
        let center = NotificationCenter()
        let tracker = FrontmostTracker(notificationCenter: center, frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        XCTAssertNil(tracker.targetApplication)
        activate(editor, in: center)
        editor.hasTerminated = true
        XCTAssertNil(tracker.targetApplication)
        browser.hasTerminated = true
        activate(browser, in: center)
        XCTAssertTrue(tracker.lastForeignApp === editor, "terminated activation must not replace history")
        front = nil
        XCTAssertNil(tracker.targetApplication)
    }

    func testContextReadersAndAXDefaultsUseForeignTargetWhilePanelIsActive() {
        var front: NSRunningApplication? = editor
        let tracker = FrontmostTracker(notificationCenter: NotificationCenter(), frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        let saved = FrontmostTracker.shared
        FrontmostTracker.shared = tracker
        defer { FrontmostTracker.shared = saved }
        front = own

        // Invalid test PIDs make AX reads harmless, while proving which
        // application's accessibility tree the production callers request.
        editor.pidReads = 0
        XCTAssertNil(EditorContextReader.current())
        XCTAssertGreaterThan(editor.pidReads, 0)
        editor.pidReads = 0
        XCTAssertTrue(AXActions.read().isEmpty)
        XCTAssertGreaterThan(editor.pidReads, 0)
        browser.pidReads = 0
        editor.pidReads = 0
        XCTAssertTrue(AXActions.read(in: browser).isEmpty)
        XCTAssertGreaterThan(browser.pidReads, 0)
        XCTAssertEqual(editor.pidReads, 0, "an explicitly chosen app still wins")
    }

    func testPhotosIntentUsesRememberedAppWithoutDeletingAnything() {
        let photos = App(-104, "com.apple.Photos")
        var front: NSRunningApplication? = photos
        let tracker = FrontmostTracker(notificationCenter: NotificationCenter(), frontmostApplication: { front },
                                       ownPID: own.pid, ownBundleIdentifier: own.bundle)
        let saved = FrontmostTracker.shared
        FrontmostTracker.shared = tracker
        defer { FrontmostTracker.shared = saved }
        front = own
        XCTAssertTrue(PhotosActions.isFrontmost())
        front = editor
        XCTAssertFalse(PhotosActions.isFrontmost())
    }

    func testInputPreparationFailsClosedWithoutTargetOrOnActivationFailure() async {
        let missing = await ActionPlanner.ensureFrontmost(nil)
        XCTAssertFalse(missing)
        editor.hasTerminated = true
        let terminated = await ActionPlanner.ensureFrontmost(editor)
        XCTAssertFalse(terminated)
        XCTAssertEqual(editor.activationCalls, 0)
        editor.hasTerminated = false
        editor.activationSucceeds = false
        let refused = await ActionPlanner.ensureFrontmost(editor)
        XCTAssertFalse(refused)
        XCTAssertEqual(editor.activationCalls, 1)
    }

    func testConfirmedInputCanPrepareForeignTargetWithoutRepeatingActivation() async {
        let prepared = await ActionPlanner.ensureFrontmost(editor)
        XCTAssertTrue(prepared)
        XCTAssertEqual(editor.activationCalls, 1)
        let alreadyActive = await ActionPlanner.ensureFrontmost(editor)
        XCTAssertTrue(alreadyActive)
        XCTAssertEqual(editor.activationCalls, 1)
    }
}
