import AppKit

/// Spotify hot-key actions driven from the phone's SPOTIFY tab. Controls the
/// Spotify desktop app through AppleScript (Automation permission, prompted
/// on first use). Works on Spotify Free; no Web API involved.
@MainActor
enum SpotifyActions {
    private static let bundleID = "com.spotify.client"
    private static let volumeStep = 10
    /// Volume before the last Mute, so the next Mute tap restores it.
    private static var mutedVolume: Int?

    struct NowPlaying {
        let track: String
        let artist: String
        let album: String
        let playing: Bool
    }

    /// Runs a remote `SPOTIFY <action>` command and reports back for a toast.
    static func perform(_ action: String, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        guard ensureRunning() else {
            status("Spotify isn't installed on this Mac.", false)
            return
        }
        switch action {
        case "PLAYPAUSE":
            ActivityLog.recordAction("spotify-playpause")
            tell("playpause")
            afterSettle { report(status, verb: nil) }
        case "NEXT":
            ActivityLog.recordAction("spotify-next")
            tell("next track")
            afterSettle { report(status, verb: "Next") }
        case "PREVIOUS":
            ActivityLog.recordAction("spotify-previous")
            tell("previous track")
            afterSettle { report(status, verb: "Previous") }
        case "VOLUME_UP":
            ActivityLog.recordAction("spotify-volume-up")
            mutedVolume = nil
            let volume = min(100, currentVolume() + volumeStep)
            tell("set sound volume to \(volume)")
            status("Spotify volume \(volume)%", true)
        case "VOLUME_DOWN":
            ActivityLog.recordAction("spotify-volume-down")
            mutedVolume = nil
            let volume = max(0, currentVolume() - volumeStep)
            tell("set sound volume to \(volume)")
            status("Spotify volume \(volume)%", true)
        case "MUTE":
            ActivityLog.recordAction("spotify-mute")
            if let restore = mutedVolume {
                mutedVolume = nil
                tell("set sound volume to \(restore)")
                status("Spotify unmuted — \(restore)%", true)
            } else {
                let current = currentVolume()
                mutedVolume = current == 0 ? 50 : current
                tell("set sound volume to 0")
                status("Spotify muted", true)
            }
        case "SHUFFLE":
            ActivityLog.recordAction("spotify-shuffle")
            let on = run("shuffling") == "true"
            tell("set shuffling to \(on ? "false" : "true")")
            status(on ? "Shuffle off" : "Shuffle on", true)
        case "REPEAT":
            ActivityLog.recordAction("spotify-repeat")
            let on = run("repeating") == "true"
            tell("set repeating to \(on ? "false" : "true")")
            status(on ? "Repeat off" : "Repeat on", true)
        case "NOW_PLAYING":
            ActivityLog.recordAction("spotify-now-playing")
            report(status, verb: nil)
        case "NEW_PLAYLIST":
            ActivityLog.recordAction("spotify-new-playlist")
            newPlaylist(status)
        case "LIKE":
            ActivityLog.recordAction("spotify-like")
            toggleLike(status)
        case _ where action.hasPrefix("ADD_CURRENT "):
            ActivityLog.recordAction("spotify-add-current")
            addCurrentTrack(toPlaylist: String(action.dropFirst(12)), status: status)
        default:
            break
        }
    }

    /// ⌥⇧B — Spotify's built-in "Save to your Liked Songs" toggle.
    private static func toggleLike(_ status: @escaping (String, Bool) -> Void) {
        guard let now = nowPlaying() else {
            status("Nothing is playing in Spotify — pick a song on your Mac first.", false)
            return
        }
        tell("activate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            KeyboardTyper.press(11, flags: [.maskAlternate, .maskShift])
            status("♥ Liked Songs toggled — \(now.track) — \(now.artist)", true)
        }
    }

    /// Adds the playing track to a playlist by name, driving Spotify's own
    /// context menu with the keyboard: right-click the now-playing title →
    /// ↓ (Add to playlist) → → (opens picker with its search focused) → ⌘A +
    /// type the name → ↓↓ (past "New playlist" to the first match) → ↩. A trailing
    /// Esc dismisses the "Already added" dialog if the song is already there.
    private static func addCurrentTrack(toPlaylist name: String, status: @escaping (String, Bool) -> Void) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status("Tell me which playlist to add to.", false)
            return
        }
        guard let now = nowPlaying() else {
            status("Nothing is playing in Spotify — pick a song on your Mac first.", false)
            return
        }
        tell("activate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let frame = mainWindowFrame() else {
                status("Couldn't find the Spotify window — is it minimized?", false)
                return
            }
            // The now-playing title sits at the bottom-left of the window,
            // just right of the 56-pt artwork; its left edge is fixed.
            let target = CGPoint(x: frame.minX + 95, y: frame.maxY - 52)
            rightClick(at: target)
            let steps: [(TimeInterval, () -> Void)] = [
                (0.7, { KeyboardTyper.press(125) }),                // ↓ Add to playlist
                (0.3, { KeyboardTyper.press(124) }),                // → open picker
                // The picker's search box remembers its last text — replace it.
                (0.5, { KeyboardTyper.press(KeyboardTyper.aKey, flags: .maskCommand) }),
                (0.2, { KeyboardTyper.type(name) }),
                (0.8, { KeyboardTyper.press(125) }),                // ↓ New playlist
                (0.2, { KeyboardTyper.press(125) }),                // ↓ first match
                (0.2, { KeyboardTyper.press(KeyboardTyper.returnKey) }),
                (1.0, { KeyboardTyper.press(KeyboardTyper.escapeKey) }),
                (0.2, { status("Added \(now.track) — \(now.artist) to “\(name)”", true) }),
            ]
            var delay: TimeInterval = 0
            for (wait, step) in steps {
                delay += wait
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
            }
        }
    }

    /// Spotify's main window in CG (top-left origin) screen coordinates.
    private static func mainWindowFrame() -> CGRect? {
        guard let raw = runSystemEvents("""
            tell process "Spotify"
                set p to position of window 1
                set s to size of window 1
                return (item 1 of p as string) & "," & (item 2 of p as string) & "," & (item 1 of s as string) & "," & (item 2 of s as string)
            end tell
            """) else { return nil }
        let n = raw.components(separatedBy: ",").compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Spotify swallows a right-click that lands the instant it's activated,
    /// so hover first, then nudge, then click.
    private static func rightClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(400_000)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x + 1, y: point.y), mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    }

    private static func runSystemEvents(_ body: String) -> String? {
        let source = "tell application \"System Events\"\n\(body)\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            NSLog("Spotify System Events script failed: \(error ?? [:])")
            return nil
        }
        return result.stringValue
    }

    /// Brings Spotify forward and triggers File → New Playlist. Spotify's
    /// AppleScript dictionary can't create playlists, so this goes through the
    /// menu bar (needs Accessibility, which the app already has for clicking).
    private static func newPlaylist(_ status: @escaping (String, Bool) -> Void) {
        tell("activate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let source = """
                tell application "System Events" to tell process "Spotify"
                    click menu item "New Playlist" of menu 1 of menu bar item "File" of menu bar 1
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                NSLog("Spotify new playlist failed: \(error)")
                status("Couldn't create a playlist — check Accessibility permission for MyClicky.", false)
            } else {
                status("New playlist created — name it in Spotify on your Mac.", true)
            }
        }
    }

    /// Track, artist, album and play state — nil if nothing is loaded.
    static func nowPlaying() -> NowPlaying? {
        guard let raw = run("""
            set t to name of current track
            set a to artist of current track
            set b to album of current track
            set s to (player state as string)
            return t & "\\n" & a & "\\n" & b & "\\n" & s
            """) else { return nil }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4, !parts[0].isEmpty else { return nil }
        return NowPlaying(track: parts[0], artist: parts[1], album: parts[2], playing: parts[3] == "playing")
    }

    private static func report(_ status: @escaping (String, Bool) -> Void, verb: String?) {
        guard let now = nowPlaying() else {
            status("Nothing is playing in Spotify — pick a song on your Mac first.", false)
            return
        }
        let state = now.playing ? "▶" : "❚❚"
        let prefix = verb.map { "\($0) · " } ?? ""
        status("\(prefix)\(state) \(now.track) — \(now.artist)", true)
    }

    private static func currentVolume() -> Int {
        Int(run("sound volume") ?? "") ?? 50
    }

    /// Launches Spotify (hidden) if installed but not running.
    private static func ensureRunning() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }

    /// Spotify needs a moment after a transport command before it reports the
    /// new track/state.
    private static func afterSettle(_ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: block)
    }

    private static func tell(_ command: String) {
        _ = run(command)
    }

    private static func run(_ body: String) -> String? {
        let source = "tell application \"Spotify\"\n\(body)\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            NSLog("Spotify AppleScript failed: \(error ?? [:])")
            return nil
        }
        return result.stringValue
    }
}
