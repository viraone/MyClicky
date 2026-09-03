import AppKit
import ApplicationServices
import OSLog

private let axlog = Logger(subsystem: "com.myclicky", category: "ax")

/// Locates on-screen controls in another app's window via the Accessibility
/// API (requires the Accessibility permission, already needed by the hotkeys).
enum AccessibilityFinder {

    /// Screen frame (AppKit coordinates, bottom-left origin) of the first text
    /// field in `app` whose title, description, or placeholder contains
    /// `needle` (case-insensitive). Returns nil if none is found.
    @MainActor
    static func textFieldFrame(in app: NSRunningApplication, matching needle: String) -> NSRect? {
        elementFrame(in: app, roles: [kAXTextFieldRole, kAXTextAreaRole], matching: needle)
    }

    /// Same as `textFieldFrame`, for buttons.
    @MainActor
    static func buttonFrame(in app: NSRunningApplication, matching needle: String) -> NSRect? {
        elementFrame(in: app, roles: [kAXButtonRole], matching: needle)
    }

    /// Screen frame of a clickable control (button or link) whose label is
    /// exactly `title` (case-insensitive) and which is actually on screen
    /// inside its window — so an off-screen duplicate isn't "clicked" at
    /// coordinates that land somewhere else.
    @MainActor
    static func visibleControlFrame(in app: NSRunningApplication, titled title: String) -> NSRect? {
        elementFrame(in: app, roles: [kAXButtonRole, "AXLink"], matching: title, exact: true, onScreenOnly: true)
    }

    /// A sidebar row with this exact label: on-screen, in the left part of the
    /// window and below its header strip (the open item's own header shares
    /// the label, and clicking that opens an info panel instead).
    @MainActor
    static func sidebarRowFrame(in app: NSRunningApplication, titled title: String) -> NSRect? {
        // The selected row is exposed as static text rather than a button.
        elementFrames(in: app, roles: [kAXButtonRole, "AXLink", kAXStaticTextRole], matching: title, exact: true, onScreenOnly: true,
                      where: { element, window in
                          guard let window else { return true }
                          return element.midX < window.minX + window.width * 0.45
                              && element.maxY < window.maxY - 60
                      })
            .min { $0.minX < $1.minX }
    }

    @MainActor
    static func elementFrame(in app: NSRunningApplication, roles: Set<String>, matching needle: String,
                             exact: Bool = false, onScreenOnly: Bool = false, quick: Bool = false) -> NSRect? {
        elementFrames(in: app, roles: roles, matching: needle, exact: exact, onScreenOnly: onScreenOnly, quick: quick).first
    }

    /// All matching frames, in tree order, from the first window that has any.
    /// Polls briefly because Chromium/Catalyst apps expose content lazily
    /// (`quick` skips the polling for a single pass).
    @MainActor
    static func elementFrames(in app: NSRunningApplication, roles: Set<String>, matching needle: String,
                              exact: Bool = false, onScreenOnly: Bool = false, quick: Bool = false,
                              where accept: ((NSRect, NSRect?) -> Bool)? = nil) -> [NSRect] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium browsers only expose web content once an assistive client
        // asks, and do so a beat later — so poll briefly before giving up.
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let lowered = needle.lowercased()
        let textMatches: (String) -> Bool = { text in
            // Some apps (WhatsApp) prefix labels with invisible bidi marks.
            let t = String(text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint })
                .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return exact ? t == lowered : t.contains(lowered)
        }
        for attempt in 0..<(quick ? 1 : 8) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            for window in windows(of: appElement) {
                let windowFrame = frame(of: window)
                var visited = 0
                var found: [NSRect] = []
                _ = search(window, budget: &visited, matches: { element in
                    guard let role = attribute(element, kAXRoleAttribute) as? String,
                          roles.contains(role) else { return false }
                    var labelled = false
                    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXValueAttribute] {
                        if let text = attribute(element, key) as? String, textMatches(text) { labelled = true; break }
                    }
                    // Links often carry their label only as a static-text child.
                    if !labelled, exact, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                        labelled = children.contains { child in
                            guard let value = attribute(child, kAXValueAttribute) as? String else { return false }
                            return textMatches(value)
                        }
                    }
                    guard labelled, let f = frame(of: element) else { return false }
                    if onScreenOnly, let windowFrame,
                       !windowFrame.insetBy(dx: 2, dy: 2).contains(NSPoint(x: f.midX, y: f.midY)) {
                        return false
                    }
                    if let accept, !accept(f, windowFrame) { return false }
                    found.append(f)
                    return false // keep walking to collect every match
                })
                if !found.isEmpty { return found }
            }
        }
        axlog.notice("no match for \(needle, privacy: .public) roles=\(roles.joined(separator: ","), privacy: .public)")
        return []
    }

    /// Focused window first, then the rest.
    private static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        if let focused = attribute(appElement, kAXFocusedWindowAttribute) { result.append(focused as! AXUIElement) }
        for window in attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? [] where !result.contains(where: { CFEqual($0, window) }) {
            result.append(window)
        }
        return result
    }

    private static func frame(of field: AXUIElement) -> NSRect? {
        guard let position = point(attribute(field, kAXPositionAttribute)),
              let size = size(attribute(field, kAXSizeAttribute)), size.width > 0, size.height > 0 else { return nil }
        // AX gives top-left-origin global coordinates; convert to AppKit.
        let mainScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: position.x, y: mainScreenMaxY - position.y - size.height,
                      width: size.width, height: size.height)
    }

    private static func search(_ element: AXUIElement, budget: inout Int,
                               matches: (AXUIElement) -> Bool) -> AXUIElement? {
        budget += 1
        if budget > 20_000 { return nil }
        if matches(element) { return element }
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let found = search(child, budget: &budget, matches: matches) { return found }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
