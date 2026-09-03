import AppKit
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "whatsapp")

/// Drives the WhatsApp desktop app through Accessibility, triggered by the
/// WhatsApp pad on the iOS remote. The chat list exposes each row as an
/// AXButton whose description is the chat name, and the search bar as an
/// element described "Search".
enum WhatsAppActions {
    static let bundleID = "net.whatsapp.WhatsApp"

    /// Opens the chat called `name`: clicks its row if it's in view, otherwise
    /// searches for it and clicks the first result.
    @MainActor
    static func openChat(named name: String, status: @escaping (_ message: String, _ ok: Bool) -> Void,
                         then next: (() -> Void)? = nil) {
        ActivityLog.recordAction("whatsapp-open-chat", ["chat": name])
        log.notice("openChat \(name, privacy: .public)")
        guard let app = ensureRunning() else {
            log.notice("WhatsApp not installed")
            status("WhatsApp isn't installed on this Mac.", false)
            return
        }
        bringForward(app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            log.notice("frontmost now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
            if let row = AccessibilityFinder.sidebarRowFrame(in: app, titled: name) {
                log.notice("row found at \(row.midX),\(row.midY)")
                MouseClicker.click(at: NSPoint(x: row.midX, y: row.midY))
                status("WhatsApp — opened \(name)", true)
                if let next { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: next) }
                return
            }
            log.notice("row not visible; searching")
            // Not in view: search for it.
            guard let search = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextFieldRole, kAXStaticTextRole, "AXSearchField"],
                matching: "search", exact: true, onScreenOnly: true
            ) else {
                status("Couldn't find WhatsApp's search box.", false)
                return
            }
            MouseClicker.click(at: NSPoint(x: search.midX, y: search.midY))
            usleep(250_000)
            KeyboardTyper.press(KeyboardTyper.aKey, flags: .maskCommand)
            KeyboardTyper.type(name)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let row = AccessibilityFinder.sidebarRowFrame(in: app, titled: name) else {
                    KeyboardTyper.press(KeyboardTyper.escapeKey)
                    status("No chat called “\(name)” found.", false)
                    return
                }
                MouseClicker.click(at: NSPoint(x: row.midX, y: row.midY))
                status("WhatsApp — opened \(name)", true)
                if let next { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: next) }
            }
        }
    }

    /// Types `text` into the compose box of the chat currently open in
    /// WhatsApp, leaving it there for the user to review and send (`send`).
    /// Text goes in via the clipboard (WhatsApp ignores synthetic Unicode key
    /// events); the previous clipboard contents are restored afterwards.
    @MainActor
    static func typeMessage(_ text: String, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("whatsapp-type", ["chars": "\(text.count)"])
        log.notice("typeMessage \(text.count) chars")
        guard let app = ensureRunning() else {
            status("WhatsApp isn't installed on this Mac.", false)
            return
        }
        bringForward(app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let box = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: "compose message", exact: false, onScreenOnly: true
            ) else {
                log.notice("compose box not found")
                status("No chat open in WhatsApp — open one first.", false)
                return
            }
            MouseClicker.click(at: NSPoint(x: box.minX + min(40, box.width / 2), y: box.midY))
            usleep(200_000)

            let saved = snapshotPasteboard()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            KeyboardTyper.press(KeyboardTyper.vKey, flags: .maskCommand)
            status("WhatsApp — typed, tap Send on your phone", true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { restorePasteboard(saved) }
        }
    }

    /// Pastes `imageData` (JPEG/PNG from the phone) into the compose box of the
    /// open chat. WhatsApp turns a pasted image into an attachment preview with
    /// a caption field; `send` then sends it.
    @MainActor
    static func attachImage(_ imageData: Data, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("whatsapp-attach-image", ["bytes": "\(imageData.count)"])
        log.notice("attachImage \(imageData.count) bytes")
        guard let image = NSImage(data: imageData), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            status("That photo couldn't be decoded.", false)
            return
        }
        guard let app = ensureRunning() else {
            status("WhatsApp isn't installed on this Mac.", false)
            return
        }
        bringForward(app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let box = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: "compose message", exact: false, onScreenOnly: true
            ) else {
                log.notice("compose box not found")
                status("No chat open in WhatsApp — open one first.", false)
                return
            }
            MouseClicker.click(at: NSPoint(x: box.minX + min(40, box.width / 2), y: box.midY))
            usleep(200_000)

            let saved = snapshotPasteboard()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            pasteboard.setData(tiff, forType: .tiff)

            KeyboardTyper.press(KeyboardTyper.vKey, flags: .maskCommand)
            status("WhatsApp — photo attached, tap Send on your phone", true)

            // The preview takes a moment to pick the image up; restore afterwards.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { restorePasteboard(saved) }
        }
    }

    private static func snapshotPasteboard() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }

    private static func restorePasteboard(_ saved: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    /// Presses Return in the compose box of the open chat, sending whatever
    /// is typed there. When an attachment preview is up instead (after
    /// `attachImage`), Return in its caption field — or its Send button —
    /// sends the attachment.
    @MainActor
    static func send(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("whatsapp-send-return", [:])
        log.notice("send (Return)")
        guard let app = ensureRunning() else {
            status("WhatsApp isn't installed on this Mac.", false)
            return
        }
        bringForward(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Attachment preview first: its caption field only exists while the
            // preview is up, and clicking the compose box underneath would
            // dismiss it.
            if let caption = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: "caption", exact: false, onScreenOnly: true, quick: true
            ) {
                MouseClicker.click(at: NSPoint(x: caption.midX, y: caption.midY))
                usleep(250_000)
                KeyboardTyper.press(KeyboardTyper.returnKey)
                status("WhatsApp — sent", true)
                return
            }
            if let box = AccessibilityFinder.elementFrame(
                in: app, roles: [kAXTextAreaRole, kAXTextFieldRole],
                matching: "compose message", exact: false, onScreenOnly: true
            ) {
                MouseClicker.click(at: NSPoint(x: box.midX, y: box.midY))
                usleep(250_000)
                pressReturnTwice()
                status("WhatsApp — sent", true)
                return
            }
            if let button = AccessibilityFinder.visibleControlFrame(in: app, titled: "send") {
                MouseClicker.click(at: NSPoint(x: button.midX, y: button.midY))
                status("WhatsApp — sent", true)
                return
            }
            status("No chat open in WhatsApp — open one first.", false)
        }
    }

    /// WhatsApp occasionally drops a synthetic Return (or is still rendering
    /// the paste), and its accessibility values lag too much to verify the
    /// box emptied — so press twice, spaced out. Return on an empty box is a
    /// no-op.
    private static func pressReturnTwice() {
        KeyboardTyper.press(KeyboardTyper.returnKey)
        usleep(1_000_000)
        KeyboardTyper.press(KeyboardTyper.returnKey)
    }

    /// Makes WhatsApp's chat window visible and frontmost: unhides the app,
    /// un-minimizes a window parked in the Dock, and — if the window was
    /// closed with the red button — asks it to reopen (like clicking its Dock
    /// icon). Plain `activate` does none of that.
    private static func bringForward(_ app: NSRunningApplication) {
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
        if windows.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // No window at all: a relaunch request on a running app is a "reopen".
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            restored = true
        }
        let activated = app.activate(options: [.activateAllWindows])
        log.notice("bringForward windows=\(windows.count) restored=\(restored) activated=\(activated)")
        if restored { usleep(500_000) }
    }

    /// Launches WhatsApp if installed but not running.
    private static func ensureRunning() -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        // Give it a moment to appear in the running list.
        for _ in 0..<20 {
            usleep(100_000)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return running
            }
        }
        return nil
    }
}
