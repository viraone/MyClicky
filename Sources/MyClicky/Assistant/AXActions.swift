import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "axactions")

/// One interactive control found on screen, for the assistant's planner to
/// reason about ("click the button labeled X").
struct AXElement {
    let role: String
    let label: String
    let value: String
    let frame: NSRect
    let enabled: Bool
}

/// Outcome of `AXActions.writeTextInBackground`. Anything but `.success`
/// means the text is NOT in the field and the caller should fall back to the
/// focus-and-return path (activate → click → paste).
enum BackgroundWriteResult: Equatable {
    /// The value was set and read back identical.
    case success
    /// The set call returned success but the value read back differs — the
    /// target accepted the call and ignored it (typical of web `contenteditable`
    /// boxes, whose real state lives in the DOM and only moves on input events).
    case verificationFailed
    /// `kAXValue` isn't settable on this element, or the set call failed.
    case elementNotWritable
    /// Accessibility isn't granted to this process (or AX is disabled).
    case permissionDenied
    /// Web content (browser app, or an element inside an `AXWebArea`) — a
    /// known-unreliable target that is never attempted; go straight to fallback.
    case unsupportedTarget

    var needsFallback: Bool { self != .success }
}

/// Generic verbs over the frontmost (or a given) app, built entirely on top
/// of `AccessibilityFinder`'s AX plumbing, `MouseClicker`, and `KeyboardTyper`
/// — no new low-level input handling. Where `WhatsAppActions` hand-scripts
/// one app, these work on whatever app is in front.
enum AXActions {

    enum ScrollDirection: String { case up, down, left, right }

    /// Roles a click can act on: buttons, links, toggles, menu items, and
    /// list/table rows (chat lists, mail lists, etc. are often plain rows).
    private static let clickableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole,
        kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuItemRole, kAXRowRole,
    ]
    /// Roles that can receive typed text.
    private static let focusableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    private static let readableRoles = clickableRoles.union(focusableRoles).union([kAXSliderRole])

    // MARK: - Read

    /// Interactive, on-screen elements of `app` (frontmost app if nil),
    /// capped at `limit` and de-duplicated by role+label+position.
    @MainActor
    static func read(in app: NSRunningApplication? = nil, limit: Int = 150) -> [AXElement] {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var results: [AXElement] = []
        var seen = Set<String>()
        for window in AccessibilityFinder.windows(of: appElement) {
            let windowFrame = AccessibilityFinder.frame(of: window)
            var visited = 0
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                if results.count >= limit { return true } // stop walking, cap reached
                guard let role = AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String,
                      readableRoles.contains(role),
                      let frame = AccessibilityFinder.frame(of: element), frame.width > 0, frame.height > 0
                else { return false }
                if let windowFrame,
                   !windowFrame.insetBy(dx: 2, dy: 2).contains(NSPoint(x: frame.midX, y: frame.midY)) {
                    return false
                }
                let label = elementLabel(element)
                guard !label.isEmpty else { return false }
                let key = "\(role)|\(label)|\(Int(frame.minX)),\(Int(frame.minY))"
                guard seen.insert(key).inserted else { return false }
                let value = (AccessibilityFinder.attribute(element, kAXValueAttribute) as? String) ?? ""
                let enabled = (AccessibilityFinder.attribute(element, kAXEnabledAttribute) as? Bool) ?? true
                results.append(AXElement(role: role, label: label, value: value, frame: frame, enabled: enabled))
                return false
            }
            if results.count >= limit { break }
        }
        log.notice("read \(results.count) elements from \(app.localizedName ?? "?", privacy: .public)")
        return results
    }

    /// Title/description/placeholder/help, falling back to a static-text
    /// child's value (links and rows often carry their label there) and then
    /// the element's own value. Strips the invisible bidi marks some apps
    /// (WhatsApp) prefix labels with.
    private static func elementLabel(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let text = AccessibilityFinder.attribute(element, key) as? String {
                let cleaned = clean(text)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        if let children = AccessibilityFinder.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                if let value = AccessibilityFinder.attribute(child, kAXValueAttribute) as? String {
                    let cleaned = clean(value)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        if let value = AccessibilityFinder.attribute(element, kAXValueAttribute) as? String {
            return clean(value)
        }
        return ""
    }

    private static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Act

    /// Clicks the on-screen control whose label contains `label`
    /// (case-insensitive). Returns false if nothing matched.
    @MainActor
    @discardableResult
    static func click(label: String, in app: NSRunningApplication? = nil) -> Bool {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication,
              let frame = AccessibilityFinder.elementFrame(in: app, roles: clickableRoles, matching: label,
                                                            exact: preferExactMatch(for: label), onScreenOnly: true)
        else {
            log.notice("click: no match for \(label, privacy: .public)")
            return false
        }
        log.notice("click: \(label, privacy: .public) -> (\(Int(frame.midX)), \(Int(frame.midY)))")
        MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
        return true
    }

    /// Clicks into the on-screen field whose label contains `label`, so
    /// subsequent `type`/`press` calls land there.
    @MainActor
    @discardableResult
    static func focus(label: String, in app: NSRunningApplication? = nil) -> Bool {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication,
              let frame = AccessibilityFinder.elementFrame(in: app, roles: focusableRoles, matching: label,
                                                            exact: preferExactMatch(for: label), onScreenOnly: true)
        else {
            log.notice("focus: no match for \(label, privacy: .public)")
            return false
        }
        log.notice("focus: \(label, privacy: .public) -> (\(Int(frame.midX)), \(Int(frame.midY)))")
        MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
        return true
    }

    /// A short/symbolic label ("+", "…", "OK") is far more likely to be a
    /// false-positive substring match (e.g. "+" matching every day cell's
    /// "+2 more" overflow indicator in Calendar) than a real distinct label
    /// — require an exact match for those instead of "contains".
    private static func preferExactMatch(for label: String) -> Bool {
        label.trimmingCharacters(in: .whitespaces).count <= 2
    }

    /// Types into whatever is currently focused, via clipboard paste. If
    /// nothing editable is focused — a shortcut or click that reveals a new
    /// field (a popover, a quick-entry box) doesn't necessarily give it
    /// keyboard focus, e.g. Calendar's Cmd+N leaves focus on a button-group
    /// container, not its "Create Quick Event" field — falls back to
    /// clicking the first on-screen editable field before pasting. Returns
    /// false only if that recovery also can't find anything to type into.
    @MainActor
    @discardableResult
    static func type(_ text: String, in app: NSRunningApplication? = nil) -> Bool {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else { return false }
        if !hasEditableFocus(in: app) {
            guard let frame = firstFocusableFrame(in: app) else {
                log.notice("type: no focused or recoverable editable field in \(app.localizedName ?? "?", privacy: .public) — skipping paste")
                dumpTree(in: app)
                return false
            }
            log.notice("type: no editable focus — clicking recovered field at (\(Int(frame.midX)), \(Int(frame.midY)))")
            MouseClicker.click(at: NSPoint(x: frame.midX, y: frame.midY))
            usleep(200_000)
            guard hasEditableFocus(in: app) else {
                log.notice("type: still no editable focus after recovery click — skipping paste")
                return false
            }
        }
        KeyboardTyper.paste(text)
        return true
    }

    private static func hasEditableFocus(in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = AccessibilityFinder.attribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let focusedElement = focused as! AXUIElement
        guard let role = AccessibilityFinder.attribute(focusedElement, kAXRoleAttribute) as? String else { return false }
        return focusableRoles.contains(role)
    }

    /// The first on-screen element with an editable role, regardless of
    /// label — used only as a last-resort focus-recovery target.
    private static func firstFocusableFrame(in app: NSRunningApplication) -> NSRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in AccessibilityFinder.windows(of: appElement) {
            let windowFrame = AccessibilityFinder.frame(of: window)
            var visited = 0
            var found: NSRect?
            _ = AccessibilityFinder.search(window, budget: &visited) { element in
                guard let role = AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String,
                      focusableRoles.contains(role),
                      let frame = AccessibilityFinder.frame(of: element), frame.width > 0, frame.height > 0
                else { return false }
                if let windowFrame, !windowFrame.insetBy(dx: 2, dy: 2).contains(NSPoint(x: frame.midX, y: frame.midY)) {
                    return false
                }
                found = frame
                return true
            }
            if let found { return found }
        }
        return nil
    }

    /// One-shot diagnostic: logs the full AX tree (every role + any
    /// title/value/placeholder), unfiltered, when focus recovery fails
    /// entirely — so the actual structure can be inspected via `log show`
    /// instead of guessed at from indirect symptoms.
    private static func dumpTree(in app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var budget = 0
        func walk(_ element: AXUIElement, depth: Int) {
            budget += 1
            guard budget <= 300, depth <= 14 else { return }
            let role = (AccessibilityFinder.attribute(element, kAXRoleAttribute) as? String) ?? "?"
            let title = (AccessibilityFinder.attribute(element, kAXTitleAttribute) as? String) ?? ""
            let value = (AccessibilityFinder.attribute(element, kAXValueAttribute) as? String) ?? ""
            let placeholder = (AccessibilityFinder.attribute(element, kAXPlaceholderValueAttribute) as? String) ?? ""
            let desc = (AccessibilityFinder.attribute(element, kAXDescriptionAttribute) as? String) ?? ""
            log.notice("axdump [\(depth, privacy: .public)] \(role, privacy: .public) title=\"\(title, privacy: .public)\" value=\"\(value, privacy: .public)\" placeholder=\"\(placeholder, privacy: .public)\" desc=\"\(desc, privacy: .public)\"")
            guard let children = AccessibilityFinder.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        log.notice("axdump: begin for \(app.localizedName ?? "?", privacy: .public)")
        for window in AccessibilityFinder.windows(of: appElement) {
            walk(window, depth: 0)
        }
        log.notice("axdump: end (\(budget, privacy: .public) nodes visited)")
    }

    /// Presses a named key (e.g. "return", "tab", "a") with optional
    /// modifiers ("cmd", "shift", "option", "control").
    @MainActor
    static func press(_ key: String, modifiers: Set<String> = []) {
        guard let code = keyCode(for: key) else {
            log.notice("press: unknown key \(key, privacy: .public)")
            return
        }
        KeyboardTyper.press(code, flags: flags(for: modifiers))
    }

    @MainActor
    static func scroll(_ direction: ScrollDirection, amount: Int32 = 12) {
        let dy: Int32
        let dx: Int32
        switch direction {
        case .up: dy = amount; dx = 0
        case .down: dy = -amount; dx = 0
        case .left: dy = 0; dx = amount
        case .right: dy = 0; dx = -amount
        }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Background write

    /// Bundle IDs whose text fields are web content; routed straight to
    /// `.unsupportedTarget` without trying.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]

    /// Sets `text` as the value of `element` — a text field in an app that is
    /// running but not frontmost — through Accessibility alone.
    ///
    /// **No-foreground contract.** This never calls `activate`,
    /// `makeKeyAndOrderFront`/`orderFront`, `AXRaise`, or posts a `CGEvent`.
    /// The frontmost app keeps focus and key status for the whole call; the
    /// target window stays where it is in the Cmd-Tab order, doesn't bounce,
    /// and renders with an inactive title bar and no caret — that's the OS's
    /// normal look for a non-key window, not a failure. Calling it repeatedly
    /// (e.g. per streaming-transcript update) replaces the value each time and
    /// the target redraws immediately.
    ///
    /// **Verify, then fall back.** After the set, the value is read back and
    /// compared; a mismatch is `.verificationFailed` rather than a silent no-op.
    /// Web content — a browser process or anything under an `AXWebArea` — is
    /// detected first and returned as `.unsupportedTarget` without trying,
    /// since `contenteditable` editors ignore raw AX sets. Callers should treat
    /// any `needsFallback` result as "use the focus-and-return path instead".
    @MainActor
    static func writeTextInBackground(to element: AXUIElement, text: String) -> BackgroundWriteResult {
        guard AXIsProcessTrusted() else {
            log.notice("bgwrite: accessibility not granted")
            return .permissionDenied
        }
        let frontBefore = NSWorkspace.shared.frontmostApplication
        if isWebContent(element) {
            log.notice("bgwrite: web content — not attempting")
            return .unsupportedTarget
        }
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settableStatus == .apiDisabled { return .permissionDenied }
        guard settableStatus == .success, settable.boolValue else {
            log.notice("bgwrite: AXValue not settable (\(settableStatus.rawValue))")
            return .elementNotWritable
        }
        let setStatus = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        switch setStatus {
        case .success: break
        case .apiDisabled: return .permissionDenied
        default:
            log.notice("bgwrite: set failed (\(setStatus.rawValue))")
            return .elementNotWritable
        }
        guard let readBack = AccessibilityFinder.attribute(element, kAXValueAttribute) as? String,
              normalizedLines(readBack) == normalizedLines(text) else {
            log.notice("bgwrite: read-back mismatch — target ignored the set")
            return .verificationFailed
        }
        let frontAfter = NSWorkspace.shared.frontmostApplication
        if frontBefore?.processIdentifier != frontAfter?.processIdentifier {
            // Can't happen from this code path; logged so a regression is loud.
            log.error("bgwrite: frontmost app changed during write (\(frontBefore?.localizedName ?? "?", privacy: .public) → \(frontAfter?.localizedName ?? "?", privacy: .public))")
        }
        log.notice("bgwrite: ok (\(text.count) chars)")
        return .success
    }

    /// Finds the editable field in `app` whose label/placeholder contains
    /// `label` and writes to it in the background. `.elementNotWritable` when
    /// no such field is exposed.
    @MainActor
    static func writeTextInBackground(in app: NSRunningApplication, fieldMatching label: String, text: String) -> BackgroundWriteResult {
        guard let element = AccessibilityFinder.element(in: app, roles: focusableRoles, matching: label,
                                                        onScreenOnly: true, quick: true) else {
            log.notice("bgwrite: no field matching \(label, privacy: .public) in \(app.localizedName ?? "?", privacy: .public)")
            return .elementNotWritable
        }
        return writeTextInBackground(to: element, text: text)
    }

    /// True when `element` belongs to a browser, or sits under an `AXWebArea`
    /// (embedded web views in otherwise-native apps).
    private static func isWebContent(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           browserBundleIDs.contains(bundleID) {
            return true
        }
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { break }
            if let role = AccessibilityFinder.attribute(node, kAXRoleAttribute) as? String, role == "AXWebArea" {
                return true
            }
            guard let parent = AccessibilityFinder.attribute(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return false
    }

    /// Text views may normalise line endings on the way in; compare on `\n`.
    private static func normalizedLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Key mapping

    private static func flags(for modifiers: Set<String>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    /// US ANSI virtual keycodes for the keys the planner is likely to name.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    private static func keyCode(for key: String) -> CGKeyCode? {
        keyCodes[key.lowercased()]
    }
}
