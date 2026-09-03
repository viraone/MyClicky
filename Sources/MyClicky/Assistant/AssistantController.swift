import AppKit
import AVFoundation

/// Orchestrates the Option+Command+C assistant:
/// hold → listen, release → capture screen + ask Claude → speak & show answer.
@MainActor
final class AssistantController {
    private let hotkey = AssistantHotkeyMonitor()
    private let dictationHotkey = AssistantHotkeyMonitor(keyCode: 9) // ⌥⌘V
    private let speech = SpeechService()
    private let capture = ScreenCaptureService()
    private let panel = AssistantPanelController()
    private let ring = HighlightRingController()
    private let synthesizer = AVSpeechSynthesizer()
    private let googleAuth = GoogleAuthService()
    private let spotify = SpotifyService()
    private let confirmPanel = ConfirmActionPanelController()
    private let toast = ToastController()
    private let remote = RemoteControlService()
    private let whatsappUnread = WhatsAppUnreadWatcher()

    private var activeScreen: NSScreen?
    private var busy = false
    /// The Claude request currently in flight, so Stop can cancel it.
    private var currentTask: Task<Void, Never>?
    /// Bumped on every new request/stop; stale tasks compare against it
    /// before touching panel state.
    private var requestID = 0
    private let speechDelegate = SpeechDelegate()
    /// Called when the iOS remote asks to start a region capture (key "5").
    var onCaptureRequest: (() -> Void)?

    /// Shows a fresh region capture in the panel's Capture + Dictate tab and
    /// puts it on the clipboard alongside the latest dictation.
    func showCapture(image: NSImage, url: URL) {
        showPanel()
        panel.state.tab = .captureDictate
        panel.state.captureImage = image
        panel.state.captureURL = url
        copyPairToClipboard()
    }
    /// True while the current listening session is dictation (⌥⌘V), not a question.
    private var dictating = false
    /// The screen rect of the last highlight ring, so "click it" knows the target.
    private var lastHighlightRect: CGRect?
    /// Confirmations a DO plan is waiting on, keyed by id — resolved by
    /// whichever answers first, the Mac's ConfirmActionPanel or the phone's
    /// CONFIRM_OK/CONFIRM_NO.
    private var pendingConfirms: [String: CheckedContinuation<Bool, Never>] = [:]

    func start() {
        panel.state.onSubmit = { [weak self] text in
            self?.handleQuestion(text)
        }
        panel.state.onStop = { [weak self] in self?.stop() }
        panel.state.onCopyAgain = { [weak self] in self?.copyPairToClipboard() }
        panel.state.onToggleDictation = { [weak self] in self?.toggleDictation() }
        panel.onHide = { [weak self] in self?.stop() }
        synthesizer.delegate = speechDelegate
        speechDelegate.onSpeakingChanged = { [weak self] speaking in
            self?.panel.state.isSpeaking = speaking
        }
        hotkey.onHoldBegan = { [weak self] in self?.beginListening() }
        hotkey.onHoldEnded = { [weak self] in self?.endListening() }
        hotkey.start()
        dictationHotkey.onHoldBegan = { [weak self] in self?.beginListening(dictation: true) }
        dictationHotkey.onHoldEnded = { [weak self] in self?.endListening() }
        dictationHotkey.start()

        // Clicky Remote (iOS app) commands over the local network.
        remote.onShow = { [weak self] in self?.showPanel() }
        remote.onListen = { [weak self] in self?.showPanel(listening: true) }
        remote.onCollapse = { [weak self] in
            guard let self else { return }
            // Enter toggles: collapse if expanded, bring back if collapsed/hidden.
            if self.panel.isVisible && !self.panel.state.collapsed {
                self.panel.minimize()
            } else if self.panel.isVisible {
                self.panel.expand()
            } else {
                self.showPanel()
            }
        }
        remote.onTab = { [weak self] name in
            guard let self else { return }
            self.showPanel()
            switch name {
            case "DICTATE", "CAPTURE", "CAPTURE_DICTATE": self.panel.state.tab = .captureDictate
            default: self.panel.state.tab = .ask
            }
        }
        remote.onCapture = { [weak self] in self?.onCaptureRequest?() }
        remote.onBrowserReload = { [weak self] in
            ActivityLog.recordAction("browser-reload")
            if !BrowserTabReader.reloadActiveTab() {
                self?.toast.show("No browser tab to refresh", icon: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        remote.onGmail = { [weak self] action in
            guard let self else { return }
            switch action {
            case "COMPOSE": GmailActions.compose()
            case "INBOX": GmailActions.openInbox()
            case "OPEN_LATEST": Task { await GmailActions.openLatest(auth: self.googleAuth) }
            case "FOCUS_SUBJECT", "FOCUS_BODY", "SEND", "REPLY":
                let report: (String, Bool) -> Void = { [weak self] message, ok in
                    let icon: String
                    switch action {
                    case "SEND": icon = "paperplane.fill"
                    case "REPLY": icon = "arrowshape.turn.up.left.fill"
                    default: icon = "textformat"
                    }
                    self?.toast.show(message,
                                     icon: ok ? icon : "exclamationmark.triangle.fill",
                                     tint: ok ? .green : .orange)
                }
                switch action {
                case "FOCUS_SUBJECT": GmailActions.focusSubject(status: report)
                case "FOCUS_BODY": GmailActions.focusBody(status: report)
                case "REPLY": GmailActions.reply(status: report)
                default: GmailActions.send(status: report)
                }
            case "TRASH_OPEN":
                Task {
                    await GmailActions.trashOpen(auth: self.googleAuth, confirm: self.confirmPanel) { [weak self] message, ok in
                        self?.toast.show(message,
                                         icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                         tint: ok ? .green : .orange)
                    }
                }
            default: break
            }
        }
        remote.onSpotify = { [weak self] action in
            guard let self else { return }
            let toast: (String, Bool) -> Void = { [weak self] message, ok in
                self?.toast.show(message,
                                 icon: ok ? "music.note" : "exclamationmark.triangle.fill",
                                 tint: ok ? .green : .orange)
            }
            if action.hasPrefix("ADD_TRACKS ") {
                Task { await self.spotifyAddTracks(String(action.dropFirst(11)), status: toast) }
            } else {
                SpotifyActions.perform(action, status: toast)
            }
        }
        remote.onWhatsApp = { [weak self] action in
            guard let self else { return }
            let report: (String, Bool) -> Void = { [weak self] message, ok in
                self?.toast.show(message,
                                 icon: ok ? "bubble.left.and.bubble.right.fill" : "exclamationmark.triangle.fill",
                                 tint: ok ? .green : .orange)
                // Echo to the phone so its status line shows what really happened here.
                self?.remote.broadcast("WHATSAPP_STATUS \(ok ? "OK" : "FAIL")\t\(message.replacingOccurrences(of: "\n", with: " "))")
            }
            if action.hasPrefix("OPEN_CHAT ") {
                let name = String(action.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                WhatsAppActions.openChat(named: name, status: report)
            } else if action == "SEND" {
                WhatsAppActions.send(status: report)
            } else if action.hasPrefix("SEND_IN ") {
                let name = String(action.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                WhatsAppActions.openChat(named: name, status: report) {
                    WhatsAppActions.send(status: report)
                }
            } else if action.hasPrefix("PHOTO_IN ") {
                // PHOTO_IN <chat>\t<base64 JPEG>
                let parts = String(action.dropFirst(9)).split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let image = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) else {
                    report("Couldn't read the photo from your phone.", false)
                    return
                }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                self.toast.show("WhatsApp — attaching photo…", icon: "photo", tint: .yellow)
                WhatsAppActions.openChat(named: name, status: report) {
                    WhatsAppActions.attachImage(image, status: report)
                }
            } else if action.hasPrefix("TYPE_TEXT ") || action.hasPrefix("TYPE_TEXT_IN ") {
                // TYPE_TEXT <text>  |  TYPE_TEXT_IN <chat>\t<text>
                var chat: String?
                var raw: String
                if action.hasPrefix("TYPE_TEXT_IN ") {
                    let parts = String(action.dropFirst(13)).split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    chat = parts[0].trimmingCharacters(in: .whitespaces)
                    raw = parts[1].trimmingCharacters(in: .whitespaces)
                } else {
                    raw = String(action.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                }
                guard !raw.isEmpty else { return }
                self.toast.show("WhatsApp — tidying your reply…", icon: "sparkles", tint: .yellow)
                Task {
                    var final = raw
                    if let apiKey = KeychainService.anthropicAPIKey() {
                        let claude = AnthropicService(apiKey: apiKey)
                        if let polished = try? await claude.cleanUpDictation(raw), !polished.isEmpty {
                            final = polished
                        }
                    }
                    if let chat, !chat.isEmpty {
                        WhatsAppActions.openChat(named: chat, status: report) {
                            WhatsAppActions.typeMessage(final, status: report)
                        }
                    } else {
                        WhatsAppActions.typeMessage(final, status: report)
                    }
                }
            }
        }
        remote.onPartial = { [weak self] text in
            guard let self, self.panel.state.status == .listening else { return }
            self.panel.state.transcript = text
        }
        remote.onDictate = { [weak self] text in
            guard let self else { return }
            self.showPanel()
            self.panel.state.tab = .captureDictate
            self.panel.state.transcript = text
            self.finishDictation(text)
        }
        remote.onAsk = { [weak self] question in
            guard let self else { return }
            self.showPanel()
            self.panel.state.transcript = question
            // The Mac's visible tab wins: if the user switched to Capture +
            // Dictate on the panel itself, treat the phone's speech as dictation.
            if self.panel.state.tab == .captureDictate {
                self.finishDictation(question)
            } else {
                self.handleQuestion(question)
            }
        }
        remote.onDo = { [weak self] utterance in
            guard let self else { return }
            self.showPanel()
            self.handleDo(utterance)
        }
        remote.onConfirmResponse = { [weak self] id, confirmed in
            self?.resolveConfirm(id: id, result: confirmed)
        }
        remote.greeting = { [weak self] in
            ["WHATSAPP_UNREAD \(self?.whatsappUnread.count ?? 0)"]
        }
        whatsappUnread.onChange = { [weak self] count in
            self?.remote.broadcast("WHATSAPP_UNREAD \(count)")
        }
        whatsappUnread.start()
        remote.start()
        ActivityLog.startSampling()
    }

    /// Brings up the assistant panel without starting local speech capture
    /// (used by the iOS remote, which records on the phone).
    private func showPanel(listening: Bool = false) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        activeScreen = screen
        if panel.state.status != .thinking {
            panel.state.status = listening ? .listening : .idle
            if listening { panel.state.transcript = "" }
            panel.state.errorText = nil
        }
        panel.show(near: cursor, on: screen)
    }

    // MARK: - Voice flow

    private func beginListening(dictation: Bool = false) {
        guard !busy else { return }
        dictating = dictation
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        activeScreen = screen

        panel.state.tab = dictation ? .captureDictate : .ask
        panel.state.status = .listening
        panel.state.transcript = ""
        panel.state.answer = ""
        panel.state.errorText = nil
        panel.show(near: cursor, on: screen)

        speech.onPartial = { [weak self] text in
            self?.panel.state.transcript = text
        }

        Task {
            guard await SpeechService.requestPermissions() else {
                self.panel.state.errorText = "Microphone or speech recognition permission was denied. Enable both for MyClicky in System Settings → Privacy & Security."
                return
            }
            do {
                try self.speech.start()
            } catch {
                self.panel.state.errorText = error.localizedDescription
            }
        }
    }

    private func endListening() {
        guard panel.state.status == .listening else { return }
        let wasDictating = dictating
        dictating = false
        Task {
            let heard = await speech.finish()
            if heard.isEmpty {
                if panel.state.errorText == nil {
                    panel.state.status = .idle
                    panel.state.transcript = wasDictating
                        ? "Didn't catch that — hold ⌥⌘V and speak."
                        : "Didn't catch that — try again, or type below."
                }
                return
            }
            panel.state.transcript = heard
            if wasDictating {
                finishDictation(heard)
            } else {
                handleQuestion(heard)
            }
        }
    }

    // MARK: - Dictation to clipboard (⌥⌘V)

    /// Mic button on the Capture + Dictate tab: first click starts recording,
    /// second click stops it and finishes the dictation (no hold required).
    private func toggleDictation() {
        if panel.state.status == .listening {
            if dictating {
                endListening()
            } else {
                stop()
            }
        } else if panel.state.status == .thinking {
            // Cancel any in-flight cleanup/answer and start a fresh dictation.
            stop()
            beginListening(dictation: true)
        } else {
            beginListening(dictation: true)
        }
    }

    private func finishDictation(_ raw: String) {
        ActivityLog.recordAction("dictate", ["text": raw])
        panel.state.tab = .captureDictate
        panel.state.status = .thinking
        panel.state.dictationText = raw
        // Copy the raw text immediately so it's usable even if cleanup fails.
        copyPairToClipboard()

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { currentTask = nil } }
            var final = raw
            if let apiKey = KeychainService.anthropicAPIKey() {
                let claude = AnthropicService(apiKey: apiKey)
                if let polished = try? await claude.cleanUpDictation(raw), !polished.isEmpty {
                    guard id == requestID else { return }
                    final = polished
                }
            }
            guard id == requestID else { return }
            panel.state.status = .answering
            panel.state.dictationText = final
            copyPairToClipboard()
        }
    }

    /// Puts the latest capture and dictation on the clipboard as a single
    /// pasteboard item carrying both image and text representations, so ⌘V
    /// pastes the image into image-aware apps and the text into text fields.
    private func copyPairToClipboard() {
        let text = panel.state.dictationText
        let image = panel.state.captureImage
        guard image != nil || !text.isEmpty else { return }

        let item = NSPasteboardItem()
        if let image, let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        if !text.isEmpty {
            item.setString(text, forType: .string)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    // MARK: - Ask Claude

    private func handleQuestion(_ question: String) {
        guard !busy else { return }
        if Self.isClickIntent(question) {
            ActivityLog.recordAction("click", ["text": question])
            handleClickCommand(question)
            return
        }
        if Self.isTrashIntent(question), !Self.isEmailIntent(question) {
            ActivityLog.recordAction("trash", [:])
            handleTrashCommand()
            return
        }
        ActivityLog.recordAction("ask", ["text": question])
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            panel.state.errorText = "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)"
            panel.state.status = .idle
            return
        }
        let screen = activeScreen ?? NSScreen.main
        guard let screen else { return }

        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            do {
                let image = try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600)
                try Task.checkCancellation()
                var context: String?
                // Email questions: feed Claude a digest of the recent inbox.
                if Self.isEmailIntent(question) {
                    panel.state.answer = "Checking your Gmail…"
                    googleAuth.onStatus = { [weak self] message in
                        self?.panel.state.answer = message
                    }
                    let gmail = GmailService(auth: googleAuth)
                    context = try await gmail.inboxDigest()
                    try Task.checkCancellation()
                }
                // If a Drive file is open in the browser, pull its full text so
                // answers cover the whole document, not just the visible part.
                if context == nil,
                   let tabURL = BrowserTabReader.activeTabURL(),
                   let fileID = DriveURLParser.fileID(from: tabURL) {
                    let drive = DriveService(auth: googleAuth)
                    if let text = try? await drive.fileText(id: fileID) {
                        context = "Full content of the document currently open in the user's browser (fetched via the Drive API — use this as the primary source; the screenshot may only show part of it):\n\n\(text)"
                    }
                    try Task.checkCancellation()
                }
                // If a code editor is frontmost, read the real file text via
                // Accessibility for far more accurate answers than pixels alone.
                if context == nil, let editor = EditorContextReader.current() {
                    context = "Actual text of the file currently focused in \(editor.appName) (read via the Accessibility API — use this as the primary source; the screenshot may only show part of it):\n\n\(editor.text)"
                }
                let claude = AnthropicService(apiKey: apiKey)
                let answer = try await claude.ask(question: question, jpegImage: image, context: context) { [weak self] status in
                    guard let self, id == self.requestID else { return }
                    self.panel.state.answer = status
                }
                try Task.checkCancellation()
                guard id == requestID else { return }
                panel.state.status = .answering
                panel.state.answer = answer.text
                if let box = answer.highlight {
                    let rect = Self.screenRect(fromNormalized: box, on: screen)
                    lastHighlightRect = rect
                    ring.show(over: rect)
                }
                speak(answer.text)
            } catch {
                // Stopped by the user — the panel was already reset in stop().
                guard id == requestID, !Task.isCancelled else { return }
                panel.state.status = .idle
                panel.state.errorText = error.localizedDescription
            }
        }
    }

    // MARK: - DO: universal voice command (any app, not just the scripted ones)

    private func handleDo(_ utterance: String) {
        guard !busy else { return }
        ActivityLog.recordAction("do", ["text": utterance])
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            let message = "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)"
            panel.state.errorText = message
            panel.state.status = .idle
            remote.broadcast("STATUS \(message.replacingOccurrences(of: "\n", with: " "))")
            return
        }
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]

        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            let callbacks = ActionPlanner.Callbacks(
                status: { [weak self] text in
                    guard let self, id == self.requestID else { return }
                    self.panel.state.status = .answering
                    self.panel.state.answer = text
                    self.remote.broadcast("STATUS \(text.replacingOccurrences(of: "\n", with: " "))")
                },
                confirm: { [weak self] question in
                    guard let self, id == self.requestID else { return false }
                    return await self.requestConfirm(question: question, screen: screen)
                }
            )
            await ActionPlanner.run(utterance: utterance, apiKey: apiKey, callbacks: callbacks) { [capture] in
                try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600)
            }
            guard id == requestID else { return }
            panel.state.status = .idle
        }
    }

    /// Shows the confirmation on the Mac panel AND sends CONFIRM to the phone;
    /// whichever answers first resolves it, since the person asking may not
    /// be within reach of the Mac.
    @MainActor
    private func requestConfirm(question: String, screen: NSScreen) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pendingConfirms[id] = continuation
            let cursor = NSEvent.mouseLocation
            confirmPanel.show(
                title: "Confirm this action?",
                message: question,
                confirmLabel: "Do It",
                icon: "checkmark.circle",
                tint: .blue,
                near: cursor,
                on: screen
            ) { [weak self] confirmed in
                self?.resolveConfirm(id: id, result: confirmed)
            }
            remote.broadcast("CONFIRM \(id)\t\(question)")
        }
    }

    private func resolveConfirm(id: String, result: Bool) {
        guard let continuation = pendingConfirms.removeValue(forKey: id) else { return }
        confirmPanel.hide()
        continuation.resume(returning: result)
    }

    /// Stops whatever Clicky is doing right now: cancels the in-flight
    /// request, silences speech, and returns the panel to Ready.
    private func stop() {
        requestID += 1
        currentTask?.cancel()
        currentTask = nil
        busy = false
        synthesizer.stopSpeaking(at: .immediate)
        panel.state.isSpeaking = false
        ring.hide()
        googleAuth.onStatus = nil
        for continuation in pendingConfirms.values { continuation.resume(returning: false) }
        pendingConfirms.removeAll()
        if panel.state.status == .listening {
            // Phone-driven listening: tell the phone to drop the recording.
            remote.broadcast("STOP")
            speech.stop()
            panel.state.status = .idle
            panel.state.transcript = ""
        } else if panel.state.status == .thinking {
            panel.state.status = .idle
            if panel.state.answer.isEmpty || panel.state.answer.hasSuffix("…") {
                panel.state.answer = "Stopped."
            }
        } else if panel.state.status == .answering {
            panel.state.status = .idle
        }
    }

    /// Maps a normalized (0–1, top-left origin) image box back to AppKit
    /// screen coordinates (points, bottom-left origin). The capture covers
    /// the entire display, so the mapping is a direct scale of its frame.
    private static func screenRect(fromNormalized box: CGRect, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + (1.0 - box.maxY) * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
    }

    // MARK: - Click-it-for-me

    /// Matches "click it", "click that", "just click it", "click the save button", …
    private static func isClickIntent(_ question: String) -> Bool {
        let lowered = question.lowercased()
        return lowered.contains("click ") || lowered == "click"
            || lowered.hasSuffix("click it") || lowered.hasSuffix("click that")
    }

    /// True when the click refers to the last highlighted element rather than
    /// naming a new one ("click it", "just click that", "click this one").
    private static func refersToLastHighlight(_ question: String) -> Bool {
        let lowered = question.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = lowered.split(separator: " ").map(String.init)
        let fillers: Set<String> = ["just", "please", "now", "ok", "okay", "yes", "go", "ahead", "and", "on"]
        let pronouns: Set<String> = ["it", "that", "this", "there", "one"]
        let rest = words.filter { $0 != "click" && !fillers.contains($0) }
        return rest.allSatisfy { pronouns.contains($0) }
    }

    private func handleClickCommand(_ question: String) {
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]

        // "Click it" → reuse the element we just highlighted.
        if Self.refersToLastHighlight(question), let rect = lastHighlightRect {
            ring.show(over: rect, duration: 30)
            confirmClick(on: rect, label: "the highlighted element", screen: screen)
            return
        }

        // "Click the save button" → ask Claude to locate it first.
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            fail("No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)")
            return
        }
        busy = true
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            do {
                let image = try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600)
                try Task.checkCancellation()
                let claude = AnthropicService(apiKey: apiKey)
                let locate = "The user wants to click something on screen. Their request: “\(question)”. Identify the exact single on-screen element they mean and return its bounding box in box_2d. In the answer, name the element briefly (e.g. “the blue Save button”)."
                let answer = try await claude.ask(question: locate, jpegImage: image) { [weak self] status in
                    guard let self, id == self.requestID else { return }
                    self.panel.state.answer = status
                }
                try Task.checkCancellation()
                guard id == requestID else { return }
                guard let box = answer.highlight else {
                    fail("I couldn't find that element on screen. Try describing it differently.")
                    return
                }
                let rect = Self.screenRect(fromNormalized: box, on: screen)
                lastHighlightRect = rect
                ring.show(over: rect, duration: 30)
                panel.state.status = .answering
                panel.state.answer = answer.text
                confirmClick(on: rect, label: answer.text, screen: screen)
            } catch {
                guard id == requestID, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func confirmClick(on rect: CGRect, label: String, screen: NSScreen) {
        panel.state.status = .answering
        let cursor = NSEvent.mouseLocation
        confirmPanel.show(
            title: "Click this?",
            message: "MyClicky will move your mouse and click \(label) — the spot inside the glowing ring.",
            confirmLabel: "Click It",
            icon: "cursorarrow.click.2",
            tint: .blue,
            near: cursor,
            on: screen
        ) { [weak self] confirmed in
            guard let self else { return }
            self.ring.hide()
            if confirmed {
                let target = NSPoint(x: rect.midX, y: rect.midY)
                MouseClicker.click(at: target)
                self.panel.state.status = .idle
                self.panel.state.answer = "Clicked!"
            } else {
                self.panel.state.status = .idle
                self.panel.state.answer = "Cancelled — nothing was clicked."
            }
        }
    }

    // MARK: - Spotify: fill a playlist

    /// `<playlist name>\t<song>|<song>|…` — creates the playlist if needed,
    /// searches each song on Spotify and appends the matches.
    private func spotifyAddTracks(_ payload: String, status: @escaping (String, Bool) -> Void) async {
        let parts = payload.components(separatedBy: "\t")
        guard parts.count == 2 else {
            status("Spotify: expected <playlist>\\t<song>|<song>…", false)
            return
        }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let queries = parts[1].components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !name.isEmpty, !queries.isEmpty else {
            status("Spotify: nothing to add.", false)
            return
        }
        ActivityLog.recordAction("spotify-add-tracks")
        spotify.onStatus = { [weak self] message in
            self?.toast.show(message, icon: "music.note", tint: .green)
        }
        defer { spotify.onStatus = nil }
        do {
            let playlist: SpotifyService.Playlist
            if let existing = try await spotify.playlist(named: name) {
                playlist = existing
            } else {
                playlist = try await spotify.createPlaylist(named: name)
            }
            status("Adding \(queries.count) songs to “\(playlist.name)”…", true)
            let result = try await spotify.add(queries: queries, to: playlist)
            var message = "Added \(result.added.count) of \(queries.count) to “\(playlist.name)”."
            if !result.missed.isEmpty {
                message += " Not found: " + result.missed.joined(separator: "; ")
            }
            NSLog("Spotify add-tracks: \(message)")
            status(message, result.missed.isEmpty)
        } catch {
            NSLog("Spotify add-tracks failed: \(error)")
            status(error.localizedDescription, false)
        }
    }

    // MARK: - Google Drive: move to trash

    /// Matches questions about the user's email/inbox — but NOT questions
    /// about the specific email visible on screen ("this email", "the email
    /// on my screen"), which are answered from the screenshot instead.
    private static func isEmailIntent(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let mentionsEmail = lowered.contains("email") || lowered.contains("gmail")
            || lowered.contains("inbox") || lowered.contains("e-mail")
        guard mentionsEmail else { return false }
        let refersToScreen = lowered.contains("this email") || lowered.contains("this e-mail")
            || lowered.contains("the email on") || lowered.contains("email on my screen")
            || lowered.contains("email i'm reading") || lowered.contains("email im reading")
            || lowered.contains("email i am reading") || lowered.contains("open email")
        return !refersToScreen
    }

    /// Matches "move this to the trash", "trash this file", "delete this", etc.
    private static func isTrashIntent(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let action = lowered.contains("trash") || lowered.contains("delete")
        let target = lowered.contains("this") || lowered.contains("file")
            || lowered.contains("it") || lowered.contains("doc")
        return action && target
    }

    private func handleTrashCommand() {
        busy = true
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil

        googleAuth.onStatus = { [weak self] message in
            self?.panel.state.answer = message
        }

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            guard let tabURL = BrowserTabReader.activeTabURL() else {
                fail("I couldn't read your browser's active tab. Make sure the file is open in Chrome or Safari, and that MyClicky is allowed under System Settings → Privacy & Security → Automation.")
                return
            }
            guard let fileID = DriveURLParser.fileID(from: tabURL) else {
                fail("The active tab doesn't look like a Google Drive file. Open the file (or folder) you want to trash, then try again.")
                return
            }
            do {
                let drive = DriveService(auth: googleAuth)
                let info = try await drive.fileInfo(id: fileID)
                try Task.checkCancellation()
                guard id == requestID else { return }
                panel.state.status = .answering
                panel.state.answer = "Confirm moving “\(info.name)” to the trash."
                let cursor = NSEvent.mouseLocation
                let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
                confirmPanel.show(
                    title: "Move to Trash?",
                    message: "“\(info.name)” will move to your Drive trash. You can restore it for 30 days.",
                    confirmLabel: "Move to Trash",
                    near: cursor,
                    on: screen
                ) { [weak self] confirmed in
                    guard let self else { return }
                    if confirmed {
                        Task { await self.performTrash(drive: drive, info: info) }
                    } else {
                        self.panel.state.status = .idle
                        self.panel.state.answer = "Cancelled — nothing was moved."
                    }
                }
            } catch {
                guard id == requestID, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func performTrash(drive: DriveService, info: DriveService.FileInfo) async {
        do {
            try await drive.trash(id: info.id)
            panel.state.status = .answering
            let message = "Moved “\(info.name)” to the trash. You can restore it from Drive's trash for 30 days."
            panel.state.answer = message
            speak("Moved \(info.name) to the trash.")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        panel.state.status = .idle
        panel.state.errorText = message
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.preferredVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.82
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    /// Picks the most natural-sounding US English female voice installed,
    /// preferring Premium > Enhanced > compact quality.
    private static let preferredVoice: AVSpeechSynthesisVoice? = {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
        let preferredNames = ["Ava", "Allison", "Zoe", "Samantha", "Nicky", "Joelle"]

        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            let quality: Int
            switch voice.quality {
            case .premium: quality = 0
            case .enhanced: quality = 1
            default: quality = 2
            }
            let name = preferredNames.firstIndex(where: { voice.name.contains($0) }) ?? preferredNames.count
            return (quality, name)
        }

        return candidates.min { rank($0) < rank($1) }
    }()
}

/// Mirrors AVSpeechSynthesizer's speaking state onto the main actor so the
/// panel can show a Stop button while Clicky is talking.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    private func report(_ speaking: Bool) {
        Task { @MainActor in self.onSpeakingChanged?(speaking) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        report(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(synthesizer.isSpeaking)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(synthesizer.isSpeaking)
    }
}
