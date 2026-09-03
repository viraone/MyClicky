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

    /// Types `text` into the frontmost focused field via clipboard paste
    /// (⌘V) instead of synthetic key events — many apps (Electron, Catalyst,
    /// web views) ignore or mangle synthetic Unicode keystrokes. Restores the
    /// previous clipboard contents afterward.
    @MainActor
    static func paste(_ text: String, restoreDelay: TimeInterval = 0.6) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(vKey, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
