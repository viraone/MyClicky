import AppKit

/// Types text and presses keys in the frontmost app using CGEvent.
/// Requires the Accessibility permission (already needed by the hotkeys).
enum KeyboardTyper {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var chars = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
    }

    static let returnKey: CGKeyCode = 36
    static let escapeKey: CGKeyCode = 53
    static let aKey: CGKeyCode = 0
    static let vKey: CGKeyCode = 9
}
