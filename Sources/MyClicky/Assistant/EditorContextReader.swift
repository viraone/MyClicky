import AppKit
import ApplicationServices

/// When a code editor (Xcode, VS Code, Cursor, Android Studio, JetBrains IDEs)
/// is the frontmost app, reads the actual text of the focused editor via the
/// Accessibility API so answers are based on real file contents, not pixels.
enum EditorContextReader {

    struct EditorContext {
        let appName: String
        let text: String
    }

    private static let maxLength = 60_000

    private static let editorBundlePrefixes = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.",           // Cursor
        "com.google.android.studio",
        "com.jetbrains.",           // IntelliJ, PyCharm, WebStorm, etc.
        "com.sublimetext.",
        "dev.zed.Zed",
    ]

    /// Returns the focused editor's text if the frontmost app is a known IDE.
    @MainActor
    static func current() -> EditorContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              editorBundlePrefixes.contains(where: { bundleID.hasPrefix($0) })
        else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        guard var text = stringValue(of: element, attribute: kAXValueAttribute)
                ?? stringValue(of: element, attribute: kAXSelectedTextAttribute),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "\n…(truncated)"
        }
        return EditorContext(appName: app.localizedName ?? "the editor", text: text)
    }

    private static func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
