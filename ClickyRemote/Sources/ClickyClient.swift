import Foundation
import Network
import AVFoundation

/// Finds the MyClicky Mac app on the local network via Bonjour
/// (_clicky._tcp) and sends it newline-terminated text commands.
@MainActor
final class ClickyClient: ObservableObject {
    enum Status: Equatable {
        case searching
        case connected
        case failed(String)
    }

    @Published var status: Status = .searching
    /// WhatsApp's unread count on the Mac (from its Dock badge). 0 = none.
    @Published var whatsappUnread = 0
    /// Gmail's unread count on the Mac (from its browser tab title). 0 = none.
    @Published var gmailUnread = 0
    /// Outcome of the last WhatsApp command as reported by the Mac.
    var onWhatsAppStatus: ((_ message: String, _ ok: Bool) -> Void)?
    /// Outcome of the last SAVE_PHOTO command as reported by the Mac.
    var onSavePhotoStatus: ((_ message: String, _ ok: Bool) -> Void)?
    /// Whether the browser window playing YouTube is currently minimized —
    /// drives the Collapse/Expand label on the YouTube pad.
    @Published var youtubeCollapsed = false
    /// Displays attached to the Mac, and which one (1-based) Peeky is on —
    /// 0 when its panel is hidden. Straight from the Mac's `SCREENS` line.
    @Published var screenCount = 1
    @Published var currentScreen = 0

    /// Progress of an in-flight DO command, or a READ description — shown in
    /// large text and spoken aloud by TALK mode.
    @Published var talkMessage = ""
    /// An irreversible DO step waiting on a yes/no answer. `sendTo` is set
    /// when the step is a message about to go out — the card then reads
    /// Cancel / Send and names the recipient.
    @Published var pendingConfirm: PendingConfirm?

    struct PendingConfirm: Equatable {
        let id: String
        let question: String
        var sendTo: String? = nil
        /// Set for a staged terminal line: the card reads Cancel / Run.
        var runIn: String? = nil
    }
    /// A pick-one prompt from the Mac (e.g. two contacts match a spoken name).
    @Published var pendingChoice: PendingChoice?

    struct PendingChoice: Equatable {
        let id: String
        let question: String
        let options: [String]
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Most recent set of discovered Mac endpoints, kept for reconnects.
    private var knownEndpoints: [NWEndpoint] = []
    private var heartbeat: Task<Void, Never>?
    private var waitingTimeout: Task<Void, Never>?
    private let speechSynthesizer = AVSpeechSynthesizer()

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_clicky._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.knownEndpoints = results.map(\.endpoint)
                if self.connection == nil, let endpoint = self.knownEndpoints.first {
                    self.connect(to: endpoint)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.status = .failed(error.localizedDescription)
                    // A failed browser never delivers another result. Leaving
                    // it failed strands the remote until the app is force
                    // quit — so tear it down and start discovery again.
                    self.browser?.cancel()
                    self.browser = nil
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.start()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // Notice a dead peer rather than waiting for a write to fail.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 3
            tcp.keepaliveCount = 2
        }
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.waitingTimeout?.cancel()
                    self.waitingTimeout = nil
                    self.status = .connected
                    self.startHeartbeat()
                case .failed, .cancelled:
                    self.connection = nil
                    self.status = .searching
                    self.scheduleReconnect()
                case .waiting:
                    // `.waiting` is normal and usually brief — it's where a
                    // connection sits while Bonjour resolves and the interface
                    // comes up. Cancelling on sight (which this used to do)
                    // kills every attempt before it can reach .ready and the
                    // remote never connects at all. It only means trouble if
                    // it *stays* waiting, so give it a grace period.
                    self.status = .searching
                    self.scheduleWaitingTimeout()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive(on: connection, buffer: "")
    }

    /// Fires for each line the Mac sends back that isn't handled here (e.g. "STOP").
    var onMacMessage: ((String) -> Void)?

    private func receive(on connection: NWConnection, buffer: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data, let chunk = String(data: data, encoding: .utf8) {
                    buffer += chunk
                    while let newline = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer = String(buffer[buffer.index(after: newline)...])
                        if line.hasPrefix("WHATSAPP_UNREAD ") {
                            self.whatsappUnread = Int(line.dropFirst(16).trimmingCharacters(in: .whitespaces)) ?? 0
                        } else if line.hasPrefix("GMAIL_UNREAD ") {
                            self.gmailUnread = Int(line.dropFirst(13).trimmingCharacters(in: .whitespaces)) ?? 0
                        } else if line.hasPrefix("WHATSAPP_STATUS ") {
                            let parts = line.dropFirst(16).split(separator: "\t", maxSplits: 1).map(String.init)
                            if parts.count == 2 { self.onWhatsAppStatus?(parts[1], parts[0] == "OK") }
                        } else if line.hasPrefix("SAVE_PHOTO_STATUS ") {
                            let parts = line.dropFirst(18).split(separator: "\t", maxSplits: 1).map(String.init)
                            if parts.count == 2 { self.onSavePhotoStatus?(parts[1], parts[0] == "OK") }
                        } else if line.hasPrefix("SCREENS ") {
                            let parts = line.dropFirst(8).split(separator: " ").compactMap { Int($0) }
                            if parts.count == 2 {
                                self.screenCount = max(1, parts[0])
                                self.currentScreen = parts[1]
                            }
                        } else if line.hasPrefix("YOUTUBE_STATE ") {
                            self.youtubeCollapsed = line.dropFirst(14).trimmingCharacters(in: .whitespaces) == "COLLAPSED"
                        } else if line.hasPrefix("STATUS ") {
                            let text = String(line.dropFirst(7))
                            self.talkMessage = text
                            self.speak(text)
                        } else if line.hasPrefix("STATUS_QUIET ") {
                            // Shown, not spoken: dictation is in progress and
                            // the mic would hear the phone talking.
                            self.talkMessage = String(line.dropFirst(13))
                        } else if line.hasPrefix("READ ") {
                            let text = String(line.dropFirst(5))
                            self.talkMessage = text
                            self.speak(text)
                        } else if line.hasPrefix("CONFIRM ") {
                            // CONFIRM <id>\t<question>[\tSEND\t<recipient>]; newlines
                            // inside a field arrive folded as U+2028.
                            let parts = line.dropFirst(8).split(separator: "\t", omittingEmptySubsequences: false)
                                .map { String($0).replacingOccurrences(of: "\u{2028}", with: "\n") }
                            if parts.count >= 2 {
                                let sendTo = (parts.count >= 4 && parts[2] == "SEND") ? parts[3] : nil
                                let runIn = (parts.count >= 4 && parts[2] == "RUN") ? parts[3] : nil
                                self.pendingConfirm = PendingConfirm(id: parts[0], question: parts[1], sendTo: sendTo, runIn: runIn)
                                if let sendTo {
                                    self.speak("Send this message to \(sendTo)?")
                                } else if let runIn {
                                    self.speak("Run this in \(runIn)?")
                                } else {
                                    self.speak(parts[1].components(separatedBy: "\n\n").first ?? parts[1])
                                }
                            }
                        } else if line.hasPrefix("CONFIRM_DONE ") {
                            // Resolved elsewhere (e.g. answered on the Mac's own
                            // panel) — clear a stale prompt if it's still up.
                            let id = line.dropFirst(13).split(separator: "\t", maxSplits: 1).map(String.init).first ?? ""
                            if self.pendingConfirm?.id == id { self.pendingConfirm = nil }
                        } else if line.hasPrefix("CHOOSE ") {
                            let parts = line.dropFirst(7).split(separator: "\t", maxSplits: 2).map(String.init)
                            if parts.count == 3 {
                                let options = parts[2].split(separator: "|").map(String.init)
                                self.pendingChoice = PendingChoice(id: parts[0], question: parts[1], options: options)
                                self.speak(parts[1] + " " + options.joined(separator: ", or "))
                            }
                        } else if line.hasPrefix("CHOOSE_DONE ") {
                            let id = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                            if self.pendingChoice?.id == id { self.pendingChoice = nil }
                        } else if !line.isEmpty {
                            self.onMacMessage?(line)
                        }
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else if self.connection === connection {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// Retries the most recently discovered endpoint after a short delay
    /// (e.g. when the Mac app was restarted).
    /// Gives a `.waiting` connection a few seconds to sort itself out before
    /// treating the peer as gone. Only armed once per wait, so repeated
    /// `.waiting` callbacks can't keep pushing the deadline out forever.
    private func scheduleWaitingTimeout() {
        guard waitingTimeout == nil else { return }
        waitingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.waitingTimeout = nil
            self.connection?.cancel()
            self.connection = nil
            self.scheduleReconnect()
        }
    }

    /// Re-establishes everything after the app comes back to the foreground.
    ///
    /// iOS suspends the app when the phone is put down, and tears the socket
    /// down with it — but `start()` only ever ran once at launch, and the
    /// suspended app's timers don't run either, so nothing noticed. The remote
    /// woke up still showing "Mac linked" and swallowed the first TALK press.
    /// A full reset costs about a second and is worth it on a remote control.
    func resume() {
        heartbeat?.cancel()
        heartbeat = nil
        waitingTimeout?.cancel()
        waitingTimeout = nil
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        status = .searching
        start()
    }

    /// Pokes the Mac every few seconds so a dead socket surfaces on its own.
    ///
    /// Without this the connection sits in `.ready` long after the Mac app has
    /// gone, and the phone keeps showing "Mac linked". The failure only
    /// surfaces when something is actually sent — so the first TALK press
    /// after a Mac restart is swallowed, and only the second one works. The
    /// Mac ignores lines it doesn't recognise, so this costs nothing there.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.connection != nil else { return }
                self.send("PING")
            }
        }
    }

    /// Keeps trying until it's back, rather than once.
    ///
    /// The single attempt this replaces gave up whenever no endpoint had been
    /// discovered yet — which is exactly the situation right after the Mac app
    /// restarts, the case it existed for. The remote then looked alive but was
    /// deaf until REFRESH was tapped by hand.
    private func scheduleReconnect(attempt: Int = 0) {
        Task { @MainActor in
            let seconds = min(8.0, 0.5 * pow(2.0, Double(attempt)))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard connection == nil else { return }
            if let endpoint = knownEndpoints.first {
                connect(to: endpoint)
            } else if attempt < 10 {
                scheduleReconnect(attempt: attempt + 1)
            } else {
                // Nothing found for a while — the browser itself may be stale.
                browser?.cancel()
                browser = nil
                start()
            }
        }
    }

    func send(_ command: String) {
        guard let connection else { return }
        let data = Data((command + "\n").utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.connection?.cancel()
                }
            }
        })
    }

    /// Speaks a STATUS/READ/CONFIRM message aloud for low-vision users.
    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speechSynthesizer.speak(AVSpeechUtterance(string: text))
    }

    /// TALK mode: universal voice command — the Mac plans and executes it.
    func talk(_ utterance: String) { send("DO \(utterance)") }
    /// "What does it say?" — the Mac replies with READ <description>.
    func read() { send("READ") }
    /// Answers the current CONFIRM prompt, if any.
    func respondConfirm(_ confirmed: Bool) {
        guard let id = pendingConfirm?.id else { return }
        send(confirmed ? "CONFIRM_OK \(id)" : "CONFIRM_NO \(id)")
        pendingConfirm = nil
    }

    /// Answers the current CHOOSE prompt, if any; nil cancels.
    func respondChoice(_ index: Int?) {
        guard let id = pendingChoice?.id else { return }
        if let index { send("CHOOSE_OK \(id)\t\(index)") } else { send("CHOOSE_NO \(id)") }
        pendingChoice = nil
    }

    func show() { send("SHOW") }
    func listen() { send("LISTEN") }
    /// A TALK recording: the Mac runs each pause-separated command as it lands.
    func listenTalk() { send("LISTEN TALK") }
    /// Recording ended with nothing to send — take the Mac out of listening too.
    func stopListening() { send("STOP") }
    func collapse() { send("COLLAPSE") }
    /// Put Peeky (panel and pointer) on display n, 1-based.
    func screen(_ n: Int) { send("SCREEN \(n)") }
    func tab(_ name: String) { send("TAB \(name)") }
    func capture() { send("CAPTURE") }
    func gmail(_ action: String) { send("GMAIL \(action)") }
    func spotify(_ action: String) { send("SPOTIFY \(action)") }
    func youtube(_ action: String) { send("YOUTUBE \(action)") }
    func whatsapp(_ action: String) { send("WHATSAPP \(action)") }
    func savePhoto(_ base64JPEG: String) { send("SAVE_PHOTO \(base64JPEG)") }
    func browserReload() { send("BROWSER RELOAD") }
    func ask(_ question: String) { send("ASK \(question)") }
    func dictate(_ text: String) { send("DICTATE \(text)") }
    /// Streams in-progress speech so the Mac panel shows words as you talk.
    func partial(_ text: String) {
        send("PARTIAL \(text.replacingOccurrences(of: "\n", with: " "))")
    }
}
