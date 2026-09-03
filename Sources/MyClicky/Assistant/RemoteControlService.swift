import Foundation
import Network

/// Local-network remote control for the assistant, used by the Clicky Remote
/// iOS app. Advertises a Bonjour service (_clicky._tcp) on the local network
/// and accepts newline-terminated text commands:
///
///   SHOW           – bring up the assistant panel
///   LISTEN         – show the panel in listening state (remote mic active)
///   COLLAPSE       – minimize the panel to its collapsed bubble
///   TAB ASK        – switch the panel to the Ask tab
///   TAB DICTATE    – switch the panel to the Capture + Dictate tab
///                    (TAB CAPTURE / TAB CAPTURE_DICTATE are aliases)
///   BROWSER RELOAD – reload the active browser tab (like ⌘R)
///   GMAIL COMPOSE  – open a new Gmail compose window in the browser
///   GMAIL INBOX    – go back to the inbox list
///   GMAIL OPEN_LATEST – open the newest Primary-inbox email
///   GMAIL FOCUS_SUBJECT – click into the Subject field of the open compose window
///   GMAIL FOCUS_BODY – click into the message body of the open compose window
///   GMAIL SEND     – click Send on the open compose window
///   GMAIL REPLY    – click Reply on the open email (cursor lands in the body)
///   SPOTIFY <action> – control the Spotify desktop app: PLAYPAUSE, NEXT,
///                    PREVIOUS, VOLUME_UP, VOLUME_DOWN, MUTE, SHUFFLE, REPEAT,
///                    NOW_PLAYING, NEW_PLAYLIST (File → New Playlist),
///                    LIKE (⌥⇧B toggle), ADD_CURRENT <playlist name> (adds the
///                    playing track via Spotify's own context menu)
///   SPOTIFY ADD_TRACKS <playlist>\t<song>|<song>… – Web API: create the
///                    playlist if needed, search each song, append matches
///   GMAIL TRASH_OPEN – trash the email open in the browser (confirm on Mac)
///   WHATSAPP OPEN_CHAT <name> – open the named chat in the WhatsApp desktop app
///   WHATSAPP TYPE_TEXT <text> – tidy the text and type it into the open chat (does not send)
///   WHATSAPP TYPE_TEXT_IN <chat>\t<text> – open the chat first, then as TYPE_TEXT
///   WHATSAPP SEND             – press Return in the open chat's compose box (send what's typed)
///   WHATSAPP SEND_IN <chat>   – open the chat first, then as SEND
///   WHATSAPP PHOTO_IN <chat>\t<base64 JPEG> – open the chat, paste the photo into
///                    its compose box as an attachment (not sent; SEND sends it)
///   DO <utterance> – universal voice command: Claude plans and executes it
///                    step by step in whatever app is frontmost (or that it
///                    opens), using only AXActions/AppDriver verbs
///   CONFIRM_OK <id> / CONFIRM_NO <id> – the phone's answer to a CONFIRM the
///                    Mac sent for an irreversible DO step
///
/// Lines the Mac sends to the phone:
///   STOP                      – recording was stopped from the Mac panel; send nothing
///   WHATSAPP_UNREAD <n>       – WhatsApp's unread badge changed (0 = cleared)
///   WHATSAPP_STATUS OK|FAIL\t<message> – outcome of the last WHATSAPP command
///   CAPTURE        – start the ⌃⌥X drag-to-select region capture
///   ASK <question> – submit a question exactly as if typed in the panel
///   DICTATE <text> – treat text as finished dictation (clipboard, paired with
///                    the latest capture, + cleanup)
///   STATUS <text>  – progress of the in-flight DO command ("Opening Mail…")
///   CONFIRM <id>\t<question> – DO wants to run an irreversible step; answer
///                    with CONFIRM_OK <id> or CONFIRM_NO <id>
@MainActor
final class RemoteControlService {
    var onShow: (() -> Void)?
    var onListen: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onTab: ((String) -> Void)?
    var onGmail: ((String) -> Void)?
    var onSpotify: ((String) -> Void)?
    var onWhatsApp: ((String) -> Void)?
    var onBrowserReload: (() -> Void)?
    var onCapture: (() -> Void)?
    var onAsk: ((String) -> Void)?
    var onDictate: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onDo: ((String) -> Void)?
    /// (id, confirmed) from CONFIRM_OK / CONFIRM_NO.
    var onConfirmResponse: ((String, Bool) -> Void)?
    /// Lines to send to a phone as soon as it connects (current state, e.g. unread counts).
    var greeting: (() -> [String])?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: "MyClicky", type: "_clicky._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("RemoteControlService failed to start: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.connections[id] = nil }
            } else if case .cancelled = state {
                Task { @MainActor in self?.connections[id] = nil }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
        for line in greeting?() ?? [] {
            connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    /// Sends a line to every connected phone (e.g. "STOP" to end recording).
    func broadcast(_ line: String) {
        let data = Data((line + "\n").utf8)
        for connection in connections.values {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Buffers raw bytes (not decoded text) so a multi-byte character or a
    /// multi-megabyte line such as PHOTO_IN can arrive split across chunks.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data {
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer = Data(buffer[buffer.index(after: newline)...])
                        let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { self.handle(line) }
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ line: String) {
        if line == "SHOW" {
            onShow?()
        } else if line == "LISTEN" {
            onListen?()
        } else if line == "COLLAPSE" {
            onCollapse?()
        } else if line == "CAPTURE" {
            onCapture?()
        } else if line.hasPrefix("TAB ") {
            onTab?(String(line.dropFirst(4)))
        } else if line == "BROWSER RELOAD" {
            onBrowserReload?()
        } else if line.hasPrefix("GMAIL ") {
            onGmail?(String(line.dropFirst(6)))
        } else if line.hasPrefix("SPOTIFY ") {
            onSpotify?(String(line.dropFirst(8)))
        } else if line.hasPrefix("WHATSAPP ") {
            onWhatsApp?(String(line.dropFirst(9)))
        } else if line.hasPrefix("PARTIAL ") {
            onPartial?(String(line.dropFirst(8)))
        } else if line.hasPrefix("DICTATE ") {
            let text = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onDictate?(text) }
        } else if line.hasPrefix("ASK ") {
            let question = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { onAsk?(question) }
        } else if line.hasPrefix("DO ") {
            let utterance = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !utterance.isEmpty { onDo?(utterance) }
        } else if line.hasPrefix("CONFIRM_OK ") {
            onConfirmResponse?(String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces), true)
        } else if line.hasPrefix("CONFIRM_NO ") {
            onConfirmResponse?(String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces), false)
        }
    }
}
