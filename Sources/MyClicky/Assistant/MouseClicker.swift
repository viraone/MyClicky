import AppKit

/// Performs a real mouse click at a point on screen using CGEvent.
/// Requires the Accessibility permission (already needed by the hotkeys).
enum MouseClicker {

    /// `point` is in AppKit screen coordinates (origin bottom-left of main screen).
    @MainActor
    static func click(at point: NSPoint) {
        // Convert AppKit (bottom-left origin) to CG global (top-left origin).
        let mainScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: mainScreenMaxY - point.y)

        let source = CGEventSource(stateID: .hidSystemState)

        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: cgPoint, mouseButton: .left)
        move?.post(tap: .cghidEventTap)

        // Small pause so the app under the cursor registers the hover first.
        usleep(120_000)

        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: cgPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: cgPoint, mouseButton: .left)
        // Catalyst apps (e.g. WhatsApp) ignore clicks whose click count is 0.
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cgSessionEventTap)
        usleep(80_000)
        up?.post(tap: .cgSessionEventTap)
    }
}
