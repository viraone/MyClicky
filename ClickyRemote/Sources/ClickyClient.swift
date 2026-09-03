import Foundation
import Network

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
    /// Outcome of the last WhatsApp command as reported by the Mac.
    var onWhatsAppStatus: ((_ message: String, _ ok: Bool) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Most recent set of discovered Mac endpoints, kept for reconnects.
    private var knownEndpoints: [NWEndpoint] = []

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
                if case .failed(let error) = state {
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = .connected
                case .failed, .cancelled:
                    self.connection = nil
                    self.status = .searching
                    self.scheduleReconnect()
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
                        } else if line.hasPrefix("WHATSAPP_STATUS ") {
                            let parts = line.dropFirst(16).split(separator: "\t", maxSplits: 1).map(String.init)
                            if parts.count == 2 { self.onWhatsAppStatus?(parts[1], parts[0] == "OK") }
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
    private func scheduleReconnect() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard connection == nil, let endpoint = knownEndpoints.first else { return }
            connect(to: endpoint)
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

    func show() { send("SHOW") }
    func listen() { send("LISTEN") }
    func collapse() { send("COLLAPSE") }
    func tab(_ name: String) { send("TAB \(name)") }
    func capture() { send("CAPTURE") }
    func gmail(_ action: String) { send("GMAIL \(action)") }
    func spotify(_ action: String) { send("SPOTIFY \(action)") }
    func whatsapp(_ action: String) { send("WHATSAPP \(action)") }
    func browserReload() { send("BROWSER RELOAD") }
    func ask(_ question: String) { send("ASK \(question)") }
    func dictate(_ text: String) { send("DICTATE \(text)") }
    /// Streams in-progress speech so the Mac panel shows words as you talk.
    func partial(_ text: String) {
        send("PARTIAL \(text.replacingOccurrences(of: "\n", with: " "))")
    }
}
