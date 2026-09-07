import AppKit
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "photos")

/// Deletes the current selection in Photos.app via Apple Events. Photos'
/// own `delete` command moves items to Recently Deleted (30-day recovery),
/// so this is trash-never-delete by default, same as Drive cleanup.
@MainActor
enum PhotosActions {
    private static let bundleID = "com.apple.Photos"

    static func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// How many media items are selected right now. Nil when Photos reports
    /// no selection (or scripting fails) — the caller treats that as
    /// "nothing to delete" rather than guessing.
    static func selectedCount() -> Int? {
        guard let text = run(#"tell application "Photos" to return count of (get selection)"#),
              let count = Int(text), count > 0 else { return nil }
        return count
    }

    static func deleteSelection(status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        // Passing the whole selection list straight to `delete` only works
        // for a single item — with more than one, Photos tries to coerce
        // the list into an album/folder and fails with error -1700. Deleting
        // one at a time in a loop is what actually works for a multi-select.
        let script = """
        tell application "Photos"
            repeat with anItem in (get selection)
                delete anItem
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            log.error("delete failed: \(error, privacy: .public)")
            status("Couldn't delete: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")", false)
            return
        }
        ActivityLog.recordAction("photos-delete")
        status("Moved to Recently Deleted.", true)
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            log.error("script failed: \(error!, privacy: .public)")
            return nil
        }
        return result.stringValue
    }
}
