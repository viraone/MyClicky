import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "keynote")

/// Keynote slideshow controls driven from the phone's KEYNOTE tab — a
/// clicker. Play, next/previous, first/last and stop go through Keynote's
/// own AppleScript verbs, which work whether or not Keynote is frontmost;
/// the in-show toggles (black, white, pointer, swap displays, switcher)
/// have no verb, so those bring Keynote forward and press the same keys
/// Keynote's slideshow already responds to.
@MainActor
enum KeynoteActions {

    /// Apple has shipped Keynote under both IDs; the running copy wins.
    private static let bundleIDs = ["com.apple.iWork.Keynote", "com.apple.Keynote"]

    typealias Status = (_ message: String, _ ok: Bool, _ playing: Bool) -> Void

    static func perform(_ action: String, status: @escaping Status) {
        if action == "OPEN" { open(status: status); return }
        guard let app = runningKeynote() else {
            status("Keynote isn't open — tap Home to open it", false, false)
            return
        }
        guard documentCount() > 0 else {
            app.activate(options: [.activateAllWindows])
            status("No presentation open in Keynote", false, false)
            return
        }
        let playing = isPlaying()
        switch action {
        case "PLAY":
            if playing {
                stop()
                status("Keynote — slideshow stopped", true, false)
            } else {
                start()
                status("Keynote — playing from the current slide", true, true)
            }
        case "SELECT":
            if playing {
                run("show next")
                status("Keynote — next", true, true)
            } else {
                start()
                status("Keynote — playing from the current slide", true, true)
            }
        case "EXIT":
            guard playing else { status("Keynote — nothing is playing", true, false); return }
            stop()
            status("Keynote — slideshow stopped", true, false)
        case "NEXT", "PREV":
            let forward = action == "NEXT"
            if playing {
                run(forward ? "show next" : "show previous")
                status(forward ? "Keynote — next" : "Keynote — previous", true, true)
            } else {
                press(forward ? "right" : "left", in: app)
                status(forward ? "Keynote — next slide selected" : "Keynote — previous slide selected", true, false)
            }
        case "FIRST", "LAST":
            let first = action == "FIRST"
            run("set current slide of front document to \(first ? "first" : "last") slide of front document")
            status(first ? "Keynote — first slide" : "Keynote — last slide", true, playing)
        case "MOVIE":
            // Keynote's in-show "Pause/Play movie" key. It only has meaning
            // while a show is running, and it is a toggle: a movie set to
            // start automatically is already playing by the time the show
            // is up, so pressing K then would pause it a second in. Outside
            // a show, just start from the current slide and let the slide's
            // own movie setting decide; the next tap pauses or plays.
            if playing {
                press("k", in: app)
                status("Keynote — video play / pause", true, true)
            } else {
                start()
                status("Keynote — playing the show; tap Video again to pause / play the movie", true, true)
            }
        case "BLACK", "WHITE", "POINTER", "SWAP":
            guard playing else { status("Start the slideshow first", false, false); return }
            let key: String
            let message: String
            switch action {
            case "BLACK": key = "b"; message = "Keynote — black screen toggled"
            case "WHITE": key = "w"; message = "Keynote — white screen toggled"
            case "POINTER": key = "c"; message = "Keynote — pointer toggled"
            default: key = "x"; message = "Keynote — displays swapped"
            }
            press(key, in: app)
            status(message, true, true)
        default:
            break
        }
    }

    /// Fire TV's Home button: Keynote to the front, launching it if needed.
    static func open(status: @escaping Status) {
        ActivityLog.recordAction("keynote-open")
        if let app = runningKeynote() {
            app.activate(options: [.activateAllWindows])
            status("Keynote — brought to the front", true, isPlaying())
            return
        }
        guard let url = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else {
            status("Couldn't find Keynote on this Mac.", false, false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    log.error("opening Keynote failed: \(error.localizedDescription, privacy: .public)")
                    status("Couldn't open Keynote.", false, false)
                } else {
                    status("Keynote — opened", true, false)
                }
            }
        }
    }

    private static func start() {
        ActivityLog.recordAction("keynote-play")
        run("start front document from current slide of front document")
    }

    private static func stop() {
        ActivityLog.recordAction("keynote-stop")
        run("stop front document")
    }

    /// Keystrokes land in whichever app is frontmost, so Keynote comes
    /// forward first and the key follows once the switch has settled.
    private static func press(_ key: String, in app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            log.notice("press \(key, privacy: .public): Accessibility not granted")
            return
        }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            AXActions.press(key)
        }
    }

    private static func runningKeynote() -> NSRunningApplication? {
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    /// Keynote's app-level `playing` flag: hidden in the dictionary as a
    /// compatibility property, but still answered by current versions.
    private static func isPlaying() -> Bool {
        run("playing")?.booleanValue ?? false
    }

    private static func documentCount() -> Int {
        Int(run("count of documents")?.int32Value ?? 0)
    }

    @discardableResult
    private static func run(_ body: String) -> NSAppleEventDescriptor? {
        let source = "tell application \"Keynote\"\n\(body)\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            log.error("keynote script failed: \(body, privacy: .public) — \(error, privacy: .public)")
            return nil
        }
        return result
    }
}
