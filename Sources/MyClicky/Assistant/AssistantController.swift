import AppKit
import AVFoundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "confirm")

/// Orchestrates the Option+Command+C assistant:
/// hold → listen, release → capture screen + ask Claude → speak & show answer.
@MainActor
final class AssistantController {
    private let hotkey = AssistantHotkeyMonitor()
    private let dictationHotkey = AssistantHotkeyMonitor(keyCode: 9) // ⌥⌘V
    private let driveCleanupHotkey = AssistantHotkeyMonitor(keyCode: 2) // ⌥⌘D
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
    private let gmailUnread = GmailUnreadWatcher()
    private let captureFileWatcher = CaptureFileWatcher()
    private let driveCleanup = DriveCleanupWindowController()
    private let breakCoach = BreakCoach()
    private let morningCoach = MorningCoach()
    /// The passage a copy verb last put on the clipboard — what "that" means
    /// in "text that to Noah". Kept apart from `NSPasteboard.general` on
    /// purpose: the system clipboard is shared with every app on the Mac and
    /// with Clicky's own paste-based typing, so it can change out from under
    /// a sentence that's still being spoken.
    private var lastCopiedText: String?
    /// Set when "email that to X" leaves a Gmail draft open, so a follow-up
    /// "send it" knows there is something to send.
    private var gmailDraftOpenedAt: Date?
    private var gmailDraftRecipient: String?
    /// Set when "open X's conversation" succeeds: the next things said are
    /// the text to X, until sent or ten minutes pass.
    private var messagesDraftOpenedAt: Date?
    private var messagesDraftRecipient: String?
    private var messagesDraftText: String?
    /// The in-flight inventory/flagging pass, so Cancel and a second ⌥⌘D can
    /// stop it rather than stacking a second scan on top.
    private var driveCleanupTask: Task<Void, Never>?

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
        panel.state.editedCaptureImage = nil
        panel.state.clipboardChoice = .edited
        copyPairToClipboard()
        captureFileWatcher.start(url: url)
    }

    /// The saved capture's file changed on disk — normally because the user
    /// clicked the preview (opening it in Preview.app), added a markup
    /// arrow, and hit ⌘S. Reloads it as a second, "edited" version so the
    /// panel can offer both, defaulting the clipboard to this new one.
    private func handleCaptureEdited(_ image: NSImage) {
        panel.state.editedCaptureImage = image
        panel.state.clipboardChoice = .edited
        copyPairToClipboard()
    }

    private func dismissCapture() {
        captureFileWatcher.stop()
        panel.state.captureImage = nil
        panel.state.captureURL = nil
        panel.state.editedCaptureImage = nil
    }
    /// What the current listening session will do with what it hears.
    private enum RecordKind { case ask, dictate, talk, morning }
    private var recordKind: RecordKind = .ask
    /// The app a Talk command should act on, captured when recording starts —
    /// Clicky's own panel is non-activating, so this stays the real target.
    private var talkTargetApp: NSRunningApplication?
    /// Talk streaming: while a Talk recording is still running, every pause
    /// hands the words said since the last pause to the planner, so "copy
    /// from import to the closing script tag … (pause) … open Dino Dad's
    /// conversation … (pause) … send that to Dino Dad … STOP" runs as three
    /// commands, each starting the moment the user stops talking.
    private var talkStreaming = false
    /// True from the first word of a Talk session until its last segment has
    /// run — the copied preview survives across segments while this is set.
    private var talkSession = false
    /// Words already run as segments this session, in transcript order.
    private var talkDispatched: [String] = []
    private var talkQueue: [String] = []
    /// Live preview of the words being said into an open Messages thread —
    /// see `streamGhostDraft`. Consumed by `handleDo` when the segment runs.
    private var ghostDraft: MessagesActions.ComposeStream?
    /// The segment (by dispatched-word count) the ghost decision was made
    /// for, so the "is the box empty?" AX read happens once per segment, not
    /// once per partial.
    private var ghostDecidedFor: Int?
    /// The screen rect of the last highlight ring, so "click it" knows the target.
    private var lastHighlightRect: CGRect?
    /// Confirmations a DO plan is waiting on, keyed by id — resolved by
    /// whichever answers first, the Mac's ConfirmActionPanel or the phone's
    /// CONFIRM_OK/CONFIRM_NO.
    private var pendingConfirms: [String: CheckedContinuation<Bool, Never>] = [:]
    private var pendingChoices: [String: CheckedContinuation<Int?, Never>] = [:]

    func start() {
        panel.state.onSubmit = { [weak self] text in
            self?.handleQuestion(text)
        }
        panel.state.onMorningSend = { [weak self] text in
            self?.handleMorning(text)
        }
        panel.state.onMorningReset = { [weak self] in
            self?.morningCoach.clearToday()
        }
        panel.state.morningMessages = morningCoach.messages
        morningCoach.onChange = { [weak self] in
            guard let self else { return }
            self.panel.state.morningMessages = self.morningCoach.messages
        }
        panel.state.onDo = { [weak self] text in
            self?.handleDo(text, targetApp: NSWorkspace.shared.frontmostApplication)
        }
        panel.state.onStop = { [weak self] in self?.stop() }
        panel.state.onCopyAgain = { [weak self] in self?.copyPairToClipboard() }
        panel.state.onDismissCapture = { [weak self] in self?.dismissCapture() }
        captureFileWatcher.onChange = { [weak self] image in self?.handleCaptureEdited(image) }
        panel.state.onReadAloud = { [weak self] in self?.replayAnswer() }
        panel.state.onToggleRecording = { [weak self] in self?.toggleRecording() }
        panel.onHide = { [weak self] in self?.stop() }
        synthesizer.delegate = speechDelegate
        speechDelegate.onSpeakingChanged = { [weak self] speaking in
            self?.panel.state.isSpeaking = speaking
        }
        hotkey.onHoldBegan = { [weak self] in self?.beginListening() }
        hotkey.onHoldEnded = { [weak self] in self?.endListening() }
        hotkey.start()
        dictationHotkey.onHoldBegan = { [weak self] in self?.beginListening(kind: .dictate) }
        dictationHotkey.onHoldEnded = { [weak self] in self?.endListening() }
        dictationHotkey.start()
        // ⌥⌘D opens Drive cleanup. Fires on key-down rather than release: it's
        // a one-shot that opens a window, not a press-and-hold like the others.
        driveCleanupHotkey.onHoldBegan = { [weak self] in self?.beginDriveCleanup() }
        driveCleanupHotkey.start()

        // Clicky Remote (iOS app) commands over the local network.
        remote.onShow = { [weak self] in self?.showPanel() }
        remote.onListen = { [weak self] in self?.showPanel(listening: true) }
        remote.onListenTalk = { [weak self] in
            guard let self else { return }
            self.talkTargetApp = NSWorkspace.shared.frontmostApplication
            self.showPanel(listening: true)
            // Phone-driven: the Mac panel is just a status readout, so park it
            // as the thin strip at the bottom of the work screen.
            if let screen = self.activeScreen { self.panel.showAsStrip(on: screen) }
            self.panel.state.tab = .talk
            self.beginTalkStreaming()
        }
        panel.state.onPause = { [weak self] in self?.talkPaused() }
        remote.onStop = { [weak self] in self?.stop() }
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
        remote.onYouTube = { [weak self] action in
            guard let self else { return }
            if action == "COLLAPSE" {
                YouTubeActions.toggleCollapse { [weak self] message, ok, collapsed in
                    self?.toast.show(message,
                                     icon: ok ? "play.rectangle.fill" : "exclamationmark.triangle.fill",
                                     tint: ok ? .red : .orange)
                    self?.remote.broadcast("YOUTUBE_STATE \(collapsed ? "COLLAPSED" : "EXPANDED")")
                }
                return
            }
            YouTubeActions.perform(action) { [weak self] message, ok in
                self?.toast.show(message,
                                 icon: ok ? "play.rectangle.fill" : "exclamationmark.triangle.fill",
                                 tint: ok ? .red : .orange)
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
        remote.onSavePhoto = { [weak self] imageData in
            guard let self else { return }
            self.toast.show("Saving photo to Desktop…", icon: "photo", tint: .yellow)
            PhotoSaveActions.save(imageData) { [weak self] message, ok in
                self?.toast.show(message,
                                 icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                 tint: ok ? .green : .orange)
                self?.remote.broadcast("SAVE_PHOTO_STATUS \(ok ? "OK" : "FAIL")\t\(message.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        remote.onPartial = { [weak self] text in
            guard let self else { return }
            self.applyPartial(text)
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
            // Capture the real target BEFORE showing our own panel — otherwise
            // if Clicky's panel itself is/becomes frontmost, the planner would
            // read and act on Clicky's own UI instead of the intended app.
            if self.talkStreaming {
                self.panel.state.transcript = utterance
                self.finishTalkStreaming(final: utterance)
                return
            }
            let targetApp = NSWorkspace.shared.frontmostApplication
            self.showPanel()
            // DO always answers on the Talk tab; force it so the result is
            // actually visible even if the panel was left on another tab.
            self.panel.state.tab = .talk
            self.panel.state.transcript = utterance
            self.handleDo(utterance, targetApp: targetApp)
        }
        remote.onConfirmResponse = { [weak self] id, confirmed in
            self?.resolveConfirm(id: id, result: confirmed)
        }
        remote.onChoiceResponse = { [weak self] id, index in
            self?.resolveChoice(id: id, index: index)
        }
        remote.onRead = { [weak self] in self?.handleReadScreen() }
        remote.greeting = { [weak self] in
            ["WHATSAPP_UNREAD \(self?.whatsappUnread.count ?? 0)",
             "GMAIL_UNREAD \(self?.gmailUnread.count ?? 0)"]
        }
        whatsappUnread.onChange = { [weak self] count in
            self?.remote.broadcast("WHATSAPP_UNREAD \(count)")
        }
        whatsappUnread.start()
        gmailUnread.onChange = { [weak self] count in
            self?.remote.broadcast("GMAIL_UNREAD \(count)")
        }
        gmailUnread.start()
        remote.start()
        ActivityLog.startSampling()
        startBreakCoach()
    }

    /// Brings up the assistant panel without starting local speech capture
    /// (used by the iOS remote, which records on the phone).
    private func showPanel(listening: Bool = false) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        activeScreen = panel.screen ?? screen
        if panel.state.status != .thinking {
            panel.state.status = listening ? .listening : .idle
            if listening { panel.state.transcript = "" }
            panel.state.errorText = nil
        }
        panel.show(near: cursor, on: screen)
    }

    // MARK: - Morning Clicky

    /// One user turn of the morning chat: Clicky replies as a coach, using
    /// the activity log and past chats, and speaks the reply. When the reply
    /// hands over to work ("first 25 minutes…") the break timer restarts so
    /// the block Clicky just proposed is the one it times.
    private func handleMorning(_ text: String) {
        guard !busy else { return }
        panel.state.tab = .morning
        panel.state.errorText = nil
        panel.state.transcript = ""
        ActivityLog.recordAction("morning", ["text": text])
        morningCoach.append(.user, text)
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            panel.state.errorText = "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)"
            panel.state.status = .idle
            return
        }
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        panel.state.status = .thinking
        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            do {
                let claude = AnthropicService(apiKey: apiKey)
                let reply = try await claude.morningChat(messages: morningCoach.messages, context: morningCoach.contextBrief())
                try Task.checkCancellation()
                guard id == requestID else { return }
                morningCoach.append(.clicky, reply)
                panel.state.status = .idle
                panel.growIfNeeded()
                if Self.handsOverToWork(reply) {
                    breakCoach.start()
                    ActivityLog.recordAction("morning-start", [:])
                }
                speak(reply)
            } catch {
                guard id == requestID, !Task.isCancelled else { return }
                panel.state.status = .idle
                panel.state.errorText = error.localizedDescription
            }
        }
    }

    /// Did Clicky just hand the user off into a focused block?
    private static func handsOverToWork(_ reply: String) -> Bool {
        let t = reply.lowercased()
        return t.contains("25") || t.contains("twenty-five") || t.contains("twenty five") || t.contains("timer")
    }

    // MARK: - Break coach

    /// Wires the 25-minute coach to the panel: a live countdown in the bottom
    /// bar, and a spoken check-in when the stretch is up.
    private func startBreakCoach() {
        panel.state.coachEnabled = breakCoach.enabled
        panel.state.coachCountdown = breakCoach.remainingLabel
        breakCoach.onChange = { [weak self] in
            guard let self else { return }
            self.panel.state.coachEnabled = self.breakCoach.enabled
            self.panel.state.coachCountdown = self.breakCoach.remainingLabel
        }
        breakCoach.onTimeUp = { [weak self] in self?.breakTimeUp() }
        panel.state.onToggleCoach = { [weak self] in
            guard let self else { return }
            self.breakCoach.enabled.toggle()
            if !self.breakCoach.enabled { self.dismissCoachCard() }
        }
        panel.state.onCoachBreak = { [weak self] in
            guard let self else { return }
            ActivityLog.recordAction("break-taken", ["after": "\(Int(self.breakCoach.elapsed / 60))"])
            self.dismissCoachCard()
            self.breakCoach.breakTaken()
        }
        panel.state.onCoachSnooze = { [weak self] in
            guard let self else { return }
            ActivityLog.recordAction("break-snoozed", ["after": "\(Int(self.breakCoach.elapsed / 60))"])
            self.dismissCoachCard()
            self.breakCoach.snooze()
        }
        breakCoach.start()
    }

    private func dismissCoachCard() {
        synthesizer.stopSpeaking(at: .immediate)
        panel.state.coachMessage = nil
    }

    /// The stretch is up: get a line from Claude about *this* stretch, bring
    /// the panel up wherever the pointer is, show it and say it. Never
    /// interrupts a recording or an answer in flight — it waits and tries on
    /// the next tick instead, by simply not being dismissed.
    private func breakTimeUp() {
        let minutes = Int(breakCoach.elapsed / 60)
        let apps = breakCoach.appsThisStretch
        let hour = Calendar.current.component(.hour, from: Date())
        ActivityLog.recordAction("break-due", ["minutes": "\(minutes)", "app": apps.first?.name ?? "?"])
        Task {
            var line = Self.fallbackCoachLine(minutes: minutes, app: apps.first?.name)
            if let apiKey = KeychainService.anthropicAPIKey() {
                let claude = AnthropicService(apiKey: apiKey)
                if let written = try? await claude.breakCheckIn(minutes: minutes, apps: apps, hour: hour) {
                    line = written
                }
            }
            // Don't talk over the user's own recording or a reply being read.
            while panel.state.status == .listening || panel.state.isSpeaking {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            showPanel()
            panel.growIfNeeded()
            panel.state.coachMessage = line
            speak(line)
        }
    }

    private static func fallbackCoachLine(minutes: Int, app: String?) -> String {
        let where_ = app.map { " in \($0)" } ?? ""
        return "That's \(minutes) minutes straight\(where_). Stand up, get a glass of water, and look at "
             + "something far away for a minute. Hours in a chair isn't good for you — the work will "
             + "still be here in five minutes, and you'll do it better."
    }

    // MARK: - Voice flow

    private func beginListening(kind: RecordKind = .ask) {
        guard !busy else { return }
        recordKind = kind
        if kind == .talk { talkTargetApp = NSWorkspace.shared.frontmostApplication }
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        activeScreen = screen

        panel.state.tab = switch kind {
        case .ask: .ask
        case .dictate: .captureDictate
        case .talk: .talk
        case .morning: .morning
        }
        panel.state.status = .listening
        panel.state.transcript = ""
        panel.state.answer = ""
        panel.state.errorText = nil
        panel.show(near: cursor, on: screen)

        speech.onPartial = { [weak self] text in
            self?.applyPartial(text)
        }
        if kind == .talk { beginTalkStreaming() }

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
        let kind = recordKind
        let target = talkTargetApp
        recordKind = .ask
        Task {
            let heard = await speech.finish()
            if kind == .talk, talkStreaming {
                if !heard.isEmpty { panel.state.transcript = heard }
                finishTalkStreaming(final: heard)
                return
            }
            if heard.isEmpty {
                if panel.state.errorText == nil {
                    panel.state.status = .idle
                    // Goes in errorText, not transcript: the Capture + Dictate
                    // tab only shows transcript while actively listening, so a
                    // message left there would be silently masked by whatever
                    // stale dictation/answer was already on screen.
                    panel.state.errorText = kind == .dictate
                        ? "Didn't catch that — hold ⌥⌘V and speak."
                        : "Didn't catch that — try again, or type below."
                }
                return
            }
            panel.state.transcript = heard
            switch kind {
            case .dictate: finishDictation(heard)
            case .ask: handleQuestion(heard)
            case .talk: handleDo(heard, targetApp: target)
            case .morning: handleMorning(heard)
            }
        }
    }

    // MARK: - Talk streaming (run each command at the pause)

    private func beginTalkStreaming() {
        talkStreaming = true
        talkSession = true
        talkDispatched = []
        talkQueue = []
        panel.state.copiedPreview = nil
        panel.state.answer = ""
    }

    /// Live transcript from either recognizer. While streaming, a segment may
    /// be running (status thinking/answering) — new words switch the panel
    /// back to listening so the phase shows recording again.
    private func applyPartial(_ text: String) {
        if talkStreaming, panel.state.status != .listening, panel.state.status != .thinking,
           text != panel.state.transcript {
            panel.state.chaining = false
            panel.state.status = .listening
        }
        guard panel.state.status == .listening else { return }
        panel.state.transcript = text
        streamGhostDraft(text)
    }

    /// Streaming dictation insert: while the user is talking to a Messages
    /// thread Clicky opened, the words appear in the compose box as they're
    /// said — written in the background, so the app they're working in keeps
    /// focus — and Claude's polished version replaces them when the sentence
    /// ends. Only on an empty compose box: with a draft already there the
    /// words are a revision or "send it", and previewing *those* over the
    /// draft would be exactly wrong. Command-shaped partials ("open David's
    /// conversation", "erase that") are never previewed.
    private func streamGhostDraft(_ transcript: String) {
        guard talkStreaming, messagesDraftOpenedAt.map({ Date().timeIntervalSince($0) < 10 * 60 }) ?? false else { return }
        let pending = pendingTalkWords(in: Self.words(transcript), quiet: true)
        // A single word is the recognizer clearing its throat; two words
        // ("send it") are more likely a command than the start of a message.
        guard pending.count >= 3 else { return }
        let utterance = pending.joined(separator: " ")
        if Self.isSendIt(utterance) || Self.isEraseIt(utterance) || Self.isUndoIt(utterance) || Self.isNeverMind(utterance) || Self.isAppCommand(utterance) {
            ghostDraft?.clear()
            return
        }
        if ghostDraft == nil {
            guard ghostDecidedFor != talkDispatched.count else { return }
            ghostDecidedFor = talkDispatched.count
            guard let stream = MessagesActions.ComposeStream.begin() else { return }
            ghostDraft = stream
            ActivityLog.recordAction("messages-ghost-start")
        }
        if ghostDraft?.update(utterance) == false {
            ghostDraft = nil
        }
    }

    /// Hands the live preview (if any) to whatever runs the segment: the
    /// drafter replaces it with Claude's text; anything else clears it.
    private func takeGhostDraft() -> MessagesActions.ComposeStream? {
        defer { ghostDraft = nil; ghostDecidedFor = nil }
        return ghostDraft
    }

    /// The recognizer went quiet: run what was said since the last pause.
    private func talkPaused() {
        guard talkStreaming, panel.state.status == .listening else { return }
        // The panel turns amber at 1.4s; give the sentence another moment
        // before acting so a mid-command breath doesn't split it in two.
        // Dictating a message gets longer still — people breathe mid-sentence
        // ("do you know where … the next open mic is") and splitting there
        // sends half a message then treats the rest as a revision.
        let snapshot = panel.state.transcript
        let grace = dictationGrace(for: snapshot) ?? 800_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: grace)
            guard let self, self.talkStreaming, self.panel.state.status == .listening,
                  self.panel.state.transcript == snapshot else { return }
            self.dispatchTalkSegment()
        }
    }

    /// Extra silence to allow before a pause ends a *message* (nil when the
    /// pending words aren't message dictation). Longer when the sentence is
    /// visibly unfinished — it trails off on "at", "the", "and", "where"…
    private func dictationGrace(for transcript: String) -> UInt64? {
        // Any words said to an open Messages thread — a fresh message being
        // previewed, or a revision to the draft — get the longer grace.
        // "Actually change that … conversation to at the Greyhound bus" was
        // split at the breath into two revisions (observed live).
        let messagesActive = messagesDraftOpenedAt.map { Date().timeIntervalSince($0) < 10 * 60 } ?? false
        guard ghostDraft != nil || messagesActive else { return nil }
        let pending = pendingTalkWords(in: Self.words(transcript), quiet: true)
        guard let last = pending.last.map(Self.normalizedWord) else { return nil }
        // Commands to the thread ("send it", "erase that", "undo") and thread
        // switches should still run promptly.
        let utterance = pending.joined(separator: " ")
        if Self.isSendIt(utterance) || Self.isEraseIt(utterance) || Self.isUndoIt(utterance) || Self.isNeverMind(utterance) || Self.isAppCommand(utterance) {
            return nil
        }
        let dangling: Set<String> = ["a", "an", "the", "and", "or", "but", "so", "to", "at", "in", "on", "of", "for",
                                     "with", "from", "by", "about", "is", "are", "was", "be", "gonna", "going", "that",
                                     "where", "when", "what", "who", "how", "if", "because", "like", "um", "uh"]
        return dangling.contains(last) ? 3_500_000_000 : 2_000_000_000
    }

    private func dispatchTalkSegment() {
        let words = Self.words(panel.state.transcript)
        let pending = pendingTalkWords(in: words)
        // Two words is the shortest real command ("open Messages"); a single
        // stray word is more likely the recognizer catching its breath.
        guard pending.count >= 2 else { return }
        talkDispatched = words
        enqueueTalk(pending.joined(separator: " "))
    }

    /// Words not yet run. The transcript normally grows — "open messages"
    /// becomes "open messages open dino dad's conversation" — so the new
    /// command is whatever follows the words already dispatched. But after a
    /// long pause the phone's recognizer often starts a fresh transcript, and
    /// skipping by count would then eat the head of the new command ("open
    /// Dino dad's conversation" arrived as "dad's conversation", observed
    /// live). So the skip only applies while the transcript still begins with
    /// what was dispatched; otherwise everything is new.
    private func pendingTalkWords(in words: [String], quiet: Bool = false) -> [String] {
        guard !talkDispatched.isEmpty else { return words }
        let prefix = talkDispatched.map(Self.normalizedWord)
        let current = words.prefix(prefix.count).map(Self.normalizedWord)
        if current.count == prefix.count, current == prefix {
            return Array(words[prefix.count...])
        }
        // The recognizer may also revise earlier words ("open" → "Open,"),
        // so accept a mostly-matching prefix before declaring a restart.
        let agree = zip(current, prefix).filter { $0 == $1 }.count
        if current.count == prefix.count, agree * 3 >= prefix.count * 2 {
            return Array(words[prefix.count...])
        }
        if !quiet {
            ActivityLog.recordAction("talk-transcript-restarted", ["dispatched": "\(prefix.count)", "now": "\(words.count)"])
        }
        return words
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// STOP: whatever is left after the last dispatched segment runs too.
    private func finishTalkStreaming(final: String) {
        talkStreaming = false
        let words = Self.words(final)
        let rest = pendingTalkWords(in: words).joined(separator: " ")
        let ranSomething = !talkDispatched.isEmpty || !talkQueue.isEmpty || busy
        talkDispatched = []
        if !rest.isEmpty {
            enqueueTalk(rest)
        } else if !ranSomething {
            takeGhostDraft()?.clear()
            talkSession = false
            panel.state.status = .idle
            panel.state.errorText = "Didn't catch that — try again, or type below."
            panel.state.logTalk(.error, "Didn't catch that.")
        } else if !busy, talkQueue.isEmpty {
            talkSession = false
            panel.state.chaining = false
            panel.state.status = panel.state.answer.isEmpty ? .idle : .answering
        }
    }

    private func enqueueTalk(_ segment: String) {
        ActivityLog.recordAction("talk-segment", ["text": segment])
        talkQueue.append(segment)
        runNextTalk()
    }

    private func runNextTalk() {
        guard !busy, !talkQueue.isEmpty else { return }
        let segment = talkQueue.removeFirst()
        // The target was captured when the session began, but a session
        // outlives a single app: start talking with VS Code focused, click
        // into Safari on the other screen, and "copy the paragraph…" should
        // read Safari — not the app that was in front minutes ago (observed
        // live: it read Clicky's own transcript back). Follow focus, unless
        // focus is on Clicky's panel, in which case the last real app stands.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            talkTargetApp = front
        }
        handleDo(segment, targetApp: talkTargetApp)
    }

    /// After a Talk plan finishes: next queued segment, or back to listening
    /// (already paused, so the panel reads "say a command"), or done.
    private func afterTalkSegment() {
        if !talkQueue.isEmpty {
            runNextTalk()
        } else if talkStreaming {
            // Hold the green "Done." so the user sees the command landed;
            // applyPartial flips back to listening the moment they speak.
            panel.state.chaining = true
            panel.state.status = .answering
        } else {
            talkSession = false
            panel.state.chaining = false
            panel.state.status = .idle
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    // MARK: - Dictation to clipboard (⌥⌘V)

    /// Mic button: first click starts recording, second click stops it and
    /// finishes the recording (no hold required) — a question on the Ask tab,
    /// a dictation on Capture + Dictate, a command to carry out on Talk.
    private func toggleRecording() {
        let kind: RecordKind = switch panel.state.tab {
        case .ask: .ask
        case .captureDictate: .dictate
        case .talk: .talk
        case .morning: .morning
        }
        if panel.state.status == .listening {
            if recordKind == kind {
                endListening()
            } else {
                // A different kind of recording is already in flight (started
                // via another tab's mic or a hotkey) — cancel it rather
                // than finalize it as the wrong kind.
                stop()
            }
        } else if panel.state.status == .thinking {
            // Cancel any in-flight cleanup/answer and start a fresh recording.
            stop()
            beginListening(kind: kind)
        } else {
            beginListening(kind: kind)
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
        let image = panel.state.imageForClipboard
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
        if MorningCoach.isGreeting(question) {
            handleMorning(question)
            return
        }
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
        // With the study site open, the answer is also rendered in the page
        // (under the box being edited) so it can be read there.
        let siteBox = SiteEditActions.editContext()
        let siteOpen = siteBox != nil || SiteEditActions.siteTabURL() != nil
        if siteOpen { SiteEditActions.showThinking(question) }

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            do {
                let image = try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600)
                try Task.checkCancellation()
                var context: String?
                // A box in edit mode is what the question is about — "explain
                // this", "what does TCP mean here" — so give Claude its text.
                if let siteBox, let box = SiteEditActions.box(siteBox.boxID) {
                    context = "The user is editing this section of a Mobile SDET study page (\(box.label)); "
                        + "their question is about it unless they say otherwise:\n\n\(box.text)"
                }
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
                if siteOpen { SiteEditActions.showReply(answer.text, question: question) }
                if let box = answer.highlight {
                    let rect = Self.screenRect(fromNormalized: box, on: screen)
                    lastHighlightRect = rect
                    ring.show(over: rect)
                }
                if !panel.state.textOnlyMode { speak(answer.text) }
            } catch {
                // Stopped by the user — the panel was already reset in stop().
                guard id == requestID, !Task.isCancelled else { return }
                if siteOpen { SiteEditActions.dismissReply() }
                panel.state.status = .idle
                panel.state.errorText = error.localizedDescription
            }
        }
    }

    // MARK: - DO: universal voice command (any app, not just the scripted ones)

    /// The screen `app`'s frontmost window sits on, by its centre point.
    private static func screenShowing(_ app: NSRunningApplication?) -> NSScreen? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AccessibilityFinder.windows(of: appElement).first,
              let frame = AccessibilityFinder.frame(of: window) else { return nil }
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
    }

    private func handleDo(_ utterance: String, targetApp: NSRunningApplication?) {
        if MorningCoach.isGreeting(utterance) {
            handleMorning(utterance)
            return
        }
        guard !busy else { return }
        ActivityLog.recordAction("do", ["text": utterance])
        panel.state.logTalk(.command, utterance)
        // A live preview of these words may already be in the Messages
        // compose box. It stays only if this segment becomes the message.
        let ghost = takeGhostDraft()
        // A box in edit mode on the study site takes whatever is said as an
        // edit to that box — checked before the Messages matchers so "delete
        // the last sentence" edits the box rather than erasing a draft.
        if let context = SiteEditActions.editContext() {
            ghost?.clear()
            if Self.isQuestionAboutBox(utterance) {
                // "Explain TCP to me with an analogy" while a box is in edit
                // mode is a question to read there, not a rewrite of the box.
                handleQuestion(utterance)
            } else if Self.isPublishIt(utterance) {
                publishSite()
            } else if Self.isDoneEditing(utterance) {
                SiteEditActions.finishEditOnPage()
                finishSiteEdit("Done editing — say “publish it” to push, or click another pencil.", ok: true)
            } else if let apiKey = KeychainService.anthropicAPIKey() {
                editSiteBox(context, instruction: utterance, apiKey: apiKey)
            } else {
                finishSiteEdit("No Anthropic API key found in Keychain.", ok: false)
            }
            return
        }
        if Self.isPublishIt(utterance), SiteEditActions.siteTabURL() != nil {
            ghost?.clear()
            publishSite()
            return
        }
        if Self.isSendIt(utterance) {
            ghost?.clear()
            sendOpenDraft()
            return
        }
        if Self.isEraseIt(utterance), messagesDraftOpenedAt.map({ Date().timeIntervalSince($0) < 10 * 60 }) ?? false {
            ghost?.clear()
            eraseOpenMessagesDraft()
            return
        }
        // "Undo that" reverts Clicky's last background write wherever it went
        // — not gated on a Messages thread, so an empty stack still gets a
        // spoken "nothing to undo" rather than being dictated somewhere.
        if Self.isUndoIt(utterance) {
            if let ghost, !ghost.written.isEmpty {
                // The last thing Clicky put on screen is the live preview
                // itself — that's what "undo that" means here, not the
                // landed write before it.
                ghost.clear()
                confirmPreviewUndone()
            } else {
                ghost?.clear()
                undoLastWrite()
            }
            return
        }
        if Self.isNeverMind(utterance), gmailDraftOpenedAt != nil || messagesDraftOpenedAt != nil {
            ghost?.clear()
            gmailDraftOpenedAt = nil
            messagesDraftOpenedAt = nil
            messagesDraftText = nil
            let message = "OK — the draft stays as it is; I'm back to taking commands."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        // "Bring up a text message with Jason Katz" went to the planner and
        // came back without an open_conversation step (observed live) — the
        // phrasing is deterministic enough to route here without Claude.
        if let name = Self.conversationOpenRequest(utterance) {
            ghost?.clear()
            openConversationDirect(named: name)
            return
        }
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            ghost?.clear()
            let message = "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)"
            panel.state.logTalk(.error, message)
            panel.state.errorText = message
            panel.state.status = .idle
            remote.broadcast("STATUS \(message.replacingOccurrences(of: "\n", with: " "))")
            return
        }
        // While a compose Clicky opened is on screen, what the user says next
        // is the email — "tell them I'm interested in the sales role" — not a
        // command. Screen-aware dictation: Claude writes it in their voice.
        // Same for a Messages thread Clicky opened. Whichever was opened more
        // recently is the one being talked to.
        // …unless it's plainly a command — "actually, open David's
        // conversation" must not get typed to Dino Dad.
        let gateBypassed = Self.isAppCommand(utterance)
        if gateBypassed { ghost?.clear() }
        let gmailActive = !gateBypassed && (gmailDraftOpenedAt.map { Date().timeIntervalSince($0) < 10 * 60 } ?? false)
        let messagesActive = !gateBypassed && (messagesDraftOpenedAt.map { Date().timeIntervalSince($0) < 10 * 60 } ?? false)
        let messagesFirst = (messagesDraftOpenedAt ?? .distantPast) > (gmailDraftOpenedAt ?? .distantPast)
        for target in messagesFirst ? ["messages", "gmail"] : ["gmail", "messages"] {
            if target == "gmail", gmailActive,
               let compose = GmailDrafter.openCompose(recipientHint: gmailDraftRecipient) {
                ghost?.clear()
                draftGmail(gist: utterance, compose: compose, apiKey: apiKey)
                return
            }
            if target == "messages", messagesActive,
               let open = MessagesActions.openConversation(),
               messagesDraftRecipient.map({ MessagesActions.spokenNameMatches($0, conversation: open) }) ?? true {
                draftMessage(gist: utterance, recipient: open, apiKey: apiKey, previewed: ghost != nil)
                return
            }
        }
        ghost?.clear()
        // Drive (and screenshot) the display the target app is actually on —
        // `activeScreen` follows the cursor, which on a multi-display setup
        // can point at a screen the app isn't even visible on, handing the
        // planner a picture with none of the UI it needs to act on.
        // The display Clicky's panel sits on is the one the user is working
        // on — they put it there. With two Safari windows on two screens,
        // this is what picks the right one to read.
        let screen = panel.screen ?? Self.screenShowing(targetApp) ?? activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        if let targetApp { AccessibilityFinder.raiseWindow(of: targetApp, on: screen) }

        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = ""
        if !talkSession { panel.state.copiedPreview = nil }
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
                    self.panel.state.logTalk(.status, text)
                    self.remote.broadcast("STATUS \(text.replacingOccurrences(of: "\n", with: " "))")
                },
                confirm: { [weak self] question in
                    guard let self, id == self.requestID else { return false }
                    return await self.requestConfirm(question: question, screen: screen)
                },
                remember: { [weak self] text in
                    guard let self else { return }
                    self.lastCopiedText = text
                    self.showCopiedText(text)
                },
                lastCopied: { [weak self] in self?.lastCopiedText },
                sendCopied: { [weak self] app, recipient, body in
                    guard let self, id == self.requestID else { return "Cancelled." }
                    return await self.sendCopied(app: app, recipient: recipient, body: body, screen: screen)
                },
                openConversation: { [weak self] app, name in
                    guard let self, id == self.requestID else { return "Cancelled." }
                    return await self.openConversation(app: app, named: name)
                },
                composeEmail: { [weak self] recipient in
                    guard let self, id == self.requestID else { return "Cancelled." }
                    return await self.composeGmail(to: recipient)
                }
            )
            await ActionPlanner.run(utterance: utterance, apiKey: apiKey, targetApp: targetApp, screen: screen, callbacks: callbacks) { [capture] in
                // Higher resolution/quality than the general ask flow — this
                // screenshot exists specifically to locate small, often
                // icon-only toolbar buttons AX couldn't label (e.g. Calendar's
                // "+"), so clarity matters more here than for scene Q&A.
                try await capture.captureDisplayJPEG(screen: screen, maxDimension: 2400, quality: 0.9,
                                                     excludingOwnWindows: true)
            }
            guard id == requestID else { return }
            busy = false
            currentTask = nil
            afterTalkSegment()
        }
    }

    /// Shows the confirmation on the Mac panel AND sends CONFIRM to the phone;
    /// whichever answers first resolves it, since the person asking may not
    /// be within reach of the Mac.
    @MainActor
    private func requestConfirm(question: String, screen: NSScreen) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            log.notice("requesting confirm \(id, privacy: .public): \(question, privacy: .public)")
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
        guard let continuation = pendingConfirms.removeValue(forKey: id) else {
            log.notice("confirm \(id, privacy: .public) resolved twice or unknown — ignored")
            return
        }
        log.notice("confirm \(id, privacy: .public) resolved: \(result ? "YES" : "NO", privacy: .public)")
        confirmPanel.hide()
        // Whichever side answered, tell every phone so a stale prompt (e.g.
        // this one was answered here on the Mac, not on the phone) clears.
        remote.broadcast("CONFIRM_DONE \(id)\t\(result ? "YES" : "NO")")
        continuation.resume(returning: result)
    }

    /// A pick-one prompt on the phone: one button per option plus Cancel.
    /// Resolves to the chosen index, or nil on cancel / after 45s of silence
    /// (so a plan can't hang forever on a question nobody saw).
    @MainActor
    private func requestChoice(question: String, options: [String]) async -> Int? {
        await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            log.notice("requesting choice \(id, privacy: .public): \(question, privacy: .public)")
            pendingChoices[id] = continuation
            remote.broadcast("CHOOSE \(id)\t\(question)\t\(options.joined(separator: "|"))")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.resolveChoice(id: id, index: nil)
            }
        }
    }

    private func resolveChoice(id: String, index: Int?) {
        guard let continuation = pendingChoices.removeValue(forKey: id) else { return }
        log.notice("choice \(id, privacy: .public) resolved: \(index.map(String.init) ?? "cancel", privacy: .public)")
        remote.broadcast("CHOOSE_DONE \(id)")
        continuation.resume(returning: index)
    }

    /// "What does it say?" from the phone: describes the frontmost window's
    /// content for someone who can't see the screen, via the same Claude
    /// vision Q&A path the assistant panel already uses.
    private func handleReadScreen() {
        guard !busy, let apiKey = KeychainService.anthropicAPIKey() else {
            remote.broadcast("READ No Anthropic API key found in Keychain on your Mac.")
            return
        }
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
        toast.show("Reading the screen for your phone…", icon: "text.viewfinder", tint: .blue)

        busy = true
        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            do {
                let image = try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600)
                let claude = AnthropicService(apiKey: apiKey)
                let question = "Describe what's on screen right now for someone who can't see it: the frontmost app, what its window shows, and any text content that matters. Plain language, 2-4 sentences, no markdown."
                let answer = try await claude.ask(question: question, jpegImage: image)
                guard id == requestID else { return }
                remote.broadcast("READ \(answer.text.replacingOccurrences(of: "\n", with: " "))")
            } catch {
                guard id == requestID else { return }
                remote.broadcast("READ Couldn't read the screen: \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
            }
        }
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
        for continuation in pendingChoices.values { continuation.resume(returning: nil) }
        pendingChoices.removeAll()
        let wasStreaming = talkStreaming
        talkStreaming = false
        takeGhostDraft()?.clear()
        talkSession = false
        panel.state.chaining = false
        talkQueue = []
        talkDispatched = []
        if wasStreaming, panel.state.status != .listening {
            remote.broadcast("STOP")
            speech.stop()
        }
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
                panel.state.logTalk(.status, "Stopped.")
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

    // MARK: - Copy by voice, then send it somewhere

    /// Shows the passage that was just copied, in the panel's existing answer
    /// area. Never spoken: a paragraph of code read aloud is useless, and the
    /// point of showing it is to be checked by eye before it goes anywhere.
    private func showCopiedText(_ text: String) {
        panel.state.status = .answering
        panel.state.copiedPreview = text
        panel.state.logTalk(.copied, AssistantPanelView.dedent(text))
        // A copied passage is for reading, and the default panel height only
        // has room for the status line above it.
        panel.growIfNeeded()
    }

    /// The name in "open Dino Dad's conversation", "bring up a text message
    /// with Jason Katz", "pull up my chat with Ben", "open up a text with
    /// Dave" — or nil when the utterance isn't plainly a request to bring a
    /// Messages thread on screen. Kept narrow: the verb must lead (after
    /// lead-ins) and the thing opened must be a message/conversation noun,
    /// so "open Safari" and "text him I'm late" don't match.
    static func conversationOpenRequest(_ utterance: String) -> String? {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'’-")))
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "clicky", "can", "could", "would", "you", "please",
                                    "now", "um", "uh", "so", "and", "then", "wait", "no", "instead", "just", "go", "let's", "lets"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        let verbs: Set<String> = ["open", "bring", "pull", "show", "start", "switch", "get"]
        guard let verb = words.first, verbs.contains(verb) else { return nil }
        words.removeFirst()
        let particles: Set<String> = ["up", "me", "to", "a", "an", "the", "my", "new", "our"]
        while let first = words.first, particles.contains(first) { words.removeFirst() }
        let nouns: Set<String> = ["text", "texts", "message", "messages", "imessage", "conversation", "convo", "chat", "thread", "sms"]
        // "… a text message with X" / "… the conversation with X" / "… chat to X"
        if let noun = words.first, nouns.contains(noun) {
            words.removeFirst()
            if let second = words.first, nouns.contains(second) { words.removeFirst() } // "text message"
            guard let joiner = words.first, ["with", "to", "for", "from"].contains(joiner) else { return nil }
            words.removeFirst()
            return cleanedContactName(words)
        }
        // "… X's conversation" / "… X's thread"
        if let index = words.firstIndex(where: { nouns.contains($0) }), index > 0,
           words[(index + 1)...].allSatisfy({ ["please", "now", "in", "messages"].contains($0) }) {
            var name = Array(words[..<index])
            if let last = name.last {
                name[name.count - 1] = last.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "’s", with: "")
            }
            return cleanedContactName(name)
        }
        return nil
    }

    private static func cleanedContactName(_ words: [String]) -> String? {
        var name = words
        let trailing: Set<String> = ["please", "now", "in", "messages", "on", "imessage", "for", "me", "thanks"]
        while let last = name.last, trailing.contains(last) { name.removeLast() }
        guard !name.isEmpty, name.count <= 5 else { return nil }
        return name.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Fast path for `conversationOpenRequest`: the same opener the planner
    /// would have called, without the round-trip (or the risk of a plan that
    /// omits it).
    private func openConversationDirect(named name: String) {
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = "Opening \(name)…"
        panel.state.errorText = nil
        remote.broadcast("STATUS \(panel.state.answer)")
        ActivityLog.recordAction("messages-open-direct", ["name": name])
        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            let reason = await openConversation(app: "Messages", named: name)
            guard id == requestID else { return }
            if let reason {
                panel.state.status = .answering
                panel.state.answer = reason
                panel.state.logTalk(.error, reason)
                remote.broadcast("STATUS \(reason.replacingOccurrences(of: "\n", with: " "))")
            } else {
                panel.state.status = .answering
                remote.broadcast("STATUS \(panel.state.answer)")
            }
            busy = false
            currentTask = nil
            afterTalkSegment()
        }
    }

    /// Brings a named conversation on screen — the spoken alternative to
    /// reaching for the mouse when the thread you want isn't the one open.
    /// Sends nothing: it exists so the thread is visible *before* the
    /// separate "text that" step puts anything into it.
    private func openConversation(app: String, named name: String) async -> String? {
        // `app` is advisory and deliberately ignored: this verb only ever
        // means Messages, and gating on it turned a request that plainly said
        // "open David Babu's conversation" into a refusal because the planner
        // filled the field in with something unexpected.
        ActivityLog.recordAction("messages-open", ["app": app.isEmpty ? "«empty»" : app])
        let matches: [MacContactsService.Match]
        do {
            matches = try await MacContactsService.numbers(for: name)
        } catch {
            ActivityLog.recordAction("messages-open-failed", ["why": "contacts-error"])
            return error.localizedDescription
        }
        // Staged so a hang shows where it stopped instead of being inferred.
        ActivityLog.recordAction("messages-open-looked-up", ["matches": "\(matches.count)"])
        // One person proceeds (their mobile, even if they have other numbers);
        // an exact name wins over a name that merely contains what was said;
        // genuinely different people get asked about — never guessed, because
        // opening the wrong thread is how the next "text that" goes astray.
        let only: MacContactsService.Match
        switch MacContactsService.resolve(matches, spoken: name) {
        case .none:
            ActivityLog.recordAction("messages-open-failed", ["why": "no-match"])
            return "No contact named “\(name)” with a phone number. "
                 + "Try their full name, or say the number itself."
        case .one(let match):
            only = match
        case .several(let people):
            ActivityLog.recordAction("messages-open-ambiguous", ["count": "\(people.count)"])
            let options = people.prefix(4).map(\.name)
            panel.state.logTalk(.status, "\(people.count) people match “\(name)” — pick one on your phone.")
            guard let index = await requestChoice(question: "Which “\(name)”?", options: Array(options)),
                  index < people.count else {
                ActivityLog.recordAction("messages-open-failed", ["why": "ambiguous", "count": "\(people.count)"])
                let list = people.prefix(6).map { "• \($0.display)" }.joined(separator: "\n")
                return "\(people.count) people match “\(name)”:\n\(list)\n\n"
                     + "Say the full name or the number you want."
            }
            only = people[index]
        }
        ActivityLog.recordAction("messages-open-url")
        let opened = await MessagesActions.openConversation(number: only.number)
        ActivityLog.recordAction("messages-open-url-done", ["ok": opened ? "yes" : "no"])
        guard opened else {
            ActivityLog.recordAction("messages-open-failed", ["why": "url-open"])
            return "Couldn't get \(only.display) open in Messages."
        }
        ActivityLog.recordAction("messages-open-conversation")
        messagesDraftOpenedAt = Date()
        messagesDraftRecipient = only.name
        messagesDraftText = nil
        // A draft already sitting in the box means the next words are a
        // revision and won't preview live — say so, or "nothing shows up
        // while I talk" looks like a failure (observed live).
        let note: String
        if let leftover = MessagesActions.currentComposeText() {
            let shown = leftover.count > 50 ? String(leftover.prefix(49)) + "…" : leftover
            note = "Opened \(only.display) in Messages — there's already a draft here: “\(shown)”. Tell me what to change, or say “erase that” to start fresh."
        } else {
            note = "Opened \(only.display) in Messages — tell me what to say, then “send it”."
        }
        panel.state.answer = note
        panel.state.logTalk(.status, note)
        return nil
    }

    /// Resolves the recipient, shows what's about to be sent, and sends it.
    ///
    /// Deliberately does not open the app: opening Messages or Gmail stays a
    /// separate spoken step, so the app is on screen and visible before
    /// anything is put into it.
    private func sendCopied(app: String, recipient: String, body: String, screen: NSScreen) async -> String? {
        switch app.lowercased() {
        case let name where name.contains("message"):
            return await sendViaMessages(recipient: recipient, body: body, screen: screen)
        case let name where name.contains("mail") || name.contains("gmail"):
            return await sendViaGmail(recipient: recipient, body: body, screen: screen)
        case let name where name.contains("whatsapp"):
            return await sendViaWhatsApp(recipient: recipient, body: body, screen: screen)
        default:
            return "I don't know how to send through \(app)."
        }
    }

    /// An open conversation IS the recipient — no contact lookup, because
    /// there's nothing to disambiguate. Only a Messages window sitting on the
    /// conversation list needs a name resolved, and that isn't supported yet.
    private func sendViaMessages(recipient: String, body: String, screen: NSScreen) async -> String? {
        guard MessagesActions.running() != nil else {
            return "Messages isn't open. Open it first, then say that again."
        }
        guard let open = MessagesActions.openConversation() else {
            return "No conversation is open in Messages. Say “open \(recipient)'s "
                 + "conversation” first, then say that again."
        }
        // Refuse rather than warn when the spoken name and the open thread
        // disagree. A confirm dialog is weakest exactly here: you asked for
        // Dino Dad, you expect Dino Dad, and a dialog naming a phone number
        // reads as noise to click past. A refusal can't be clicked past, and
        // a wrong send can't be taken back.
        guard MessagesActions.spokenNameMatches(recipient, conversation: open) else {
            ActivityLog.recordAction("messages-name-mismatch")
            return "You said “\(recipient)”, but the conversation that's open is \(open). "
                 + "Say “open \(recipient)'s conversation” first — or say “text that” "
                 + "to send to the one that's already open."
        }
        guard await confirmSend(to: open, via: "Messages", body: body, screen: screen) else {
            return "Cancelled — nothing was sent."
        }
        var failure: String?
        MessagesActions.sendToOpenConversation(body) { [weak self] message, success in
            if success {
                self?.panel.state.answer = message
                self?.panel.state.logTalk(.status, message)
            } else { failure = message }
        }
        return failure
    }

    /// Gmail resolves the name against real contacts — Google Contacts first,
    /// then the Mac address book, which is where the people Messages knows
    /// actually live. One match proceeds, several stop and ask, none says so
    /// plainly — never a guess, because the wrong Ben is not a recoverable
    /// mistake.
    private func sendViaGmail(recipient: String, body: String, screen: NSScreen) async -> String? {
        let only: ContactsService.Match
        switch await gmailRecipient(named: recipient) {
        case .success(let match): only = match
        case .failure(let reason): return reason.message
        }
        guard await confirmSend(to: only.display, via: "Gmail", body: body, screen: screen) else {
            return "Cancelled — nothing was sent."
        }
        GmailActions.composeTo(only.email, body: body)
        gmailDraftOpenedAt = Date()
        gmailDraftRecipient = only.display
        let note = "Drafted to \(only.display) in Gmail — say “send it” or press Send when it looks right."
        panel.state.answer = note
        panel.state.logTalk(.status, note)
        return nil
    }

    /// "Send it", "send the email", "send that" — a handful of words, no
    /// planner round trip. Only fires while a Gmail draft Clicky opened is
    /// plausibly still on screen, so a stray "send" in normal speech won't
    /// mail a half-written message.
    private static func isSendIt(_ utterance: String) -> Bool {
        let words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // "Looks good to me, send it" — an approval may lead in.
        let approval: Set<String> = ["ok", "okay", "looks", "good", "great", "perfect", "yes", "yeah", "yep",
                                     "alright", "all", "right", "and", "now", "go", "ahead", "please", "then",
                                     "that", "that's", "thats", "it's", "its", "fine", "cool", "nice", "to", "me", "just",
                                     "can", "could", "would", "you", "let's", "lets", "hey", "clicky", "hit", "press"]
        // "sent" is a common transcription of "send"; "fire/shoot it off" are colloquial sends.
        let sendVerbs: Set<String> = ["send", "sent", "fire", "shoot", "ship"]
        guard let sendAt = words.firstIndex(where: { sendVerbs.contains($0) }), words.count - sendAt <= 6,
              words[..<sendAt].count <= 6, words[..<sendAt].allSatisfy({ approval.contains($0) }) else { return false }
        let filler: Set<String> = ["it", "that", "this", "the", "a", "email", "mail", "message", "text", "texts",
                                   "sms", "imessage", "draft", "reply", "response", "now", "please", "off", "out",
                                   "away", "over", "along", "him", "her", "them", "to", "for", "me", "button"]
        return words[(sendAt + 1)...].allSatisfy { filler.contains($0) }
    }

    /// "Erase that", "delete the whole message", "clear it", "start over" —
    /// empty the draft rather than revise it. The drafter can't express
    /// "nothing" (an empty reply is treated as a failure), so left to Claude
    /// this reads as a revision and the text simply stays put.
    private static func isEraseIt(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "clicky", "no", "wait", "please", "just", "can", "you", "let's", "lets", "and", "now"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        let joined = words.joined(separator: " ")
        if ["start over", "start again", "scrap that", "scrap it", "wipe it", "wipe that", "get rid of"].contains(where: { joined.hasPrefix($0) }) {
            return true
        }
        let verbs: Set<String> = ["erase", "delete", "clear", "remove", "wipe", "scrap"]
        guard let verb = words.first, verbs.contains(verb), words.count <= 7 else { return false }
        let filler: Set<String> = ["it", "that", "this", "the", "whole", "entire", "all", "of", "message", "text",
                                   "draft", "everything", "please", "now", "out", "away", "completely"]
        return words.dropFirst().allSatisfy { filler.contains($0) }
    }

    private static func isNeverMind(_ utterance: String) -> Bool {
        let t = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["never mind", "nevermind", "cancel", "cancel that", "stop", "forget it", "leave it"].contains(t)
    }

    /// "Undo that", "undo", "put it back", "revert that", "never mind, undo"
    /// — revert Clicky's last background write. Kept tight (a verb plus
    /// filler) so "undo the second sentence" stays a revision for the drafter.
    static func isUndoIt(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "clicky", "no", "wait", "please", "just", "can", "you",
                                    "let's", "lets", "and", "now", "never", "mind", "nevermind", "oops", "uh", "um", "sorry"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        guard !words.isEmpty else { return false }
        let filler: Set<String> = ["it", "that", "this", "the", "last", "one", "thing", "write", "change", "edit",
                                   "message", "text", "draft", "please", "now", "again"]
        let phrases = ["put it back", "put that back", "put the text back", "put my text back", "take that back", "take it back",
                       "bring it back", "bring that back", "change it back", "go back to what it was", "go back to how it was"]
        for phrase in phrases.map({ $0.split(separator: " ").map(String.init) })
        where words.count <= phrase.count + 3 && words.starts(with: phrase) {
            // "Put it back on the shelf tomorrow" is dictation; only the bare
            // phrase (plus filler) is the command.
            return words.dropFirst(phrase.count).allSatisfy { filler.contains($0) }
        }
        let verbs: Set<String> = ["undo", "revert", "unsend"]
        guard let verb = words.first, verbs.contains(verb), words.count <= 6 else { return false }
        return words.dropFirst().allSatisfy { filler.contains($0) }
    }

    /// Speech that is clearly an instruction to Clicky rather than words for
    /// the open draft: "actually, let's open up a conversation with David",
    /// "switch to Safari", "write an email to Sam". Checked after stripping
    /// lead-ins, so a message that merely *contains* "open" still counts as
    /// dictation ("tell him the store is open till nine").
    static func isAppCommand(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "clicky", "let's", "lets", "can", "could", "you",
                                    "please", "now", "um", "uh", "so", "and", "then", "wait", "no", "instead", "just", "go"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        guard let verb = words.first else { return false }
        let commandVerbs: Set<String> = ["open", "switch", "close", "minimize", "minimise", "quit", "launch", "start",
                                         "show", "bring", "pull", "compose", "screenshot", "search", "google", "copy",
                                         "paste", "scroll", "click", "focus", "restore", "hide", "maximize", "maximise"]
        if commandVerbs.contains(verb) { return true }
        let joined = words.joined(separator: " ")
        let phrases = ["write an email", "write a new email", "send an email", "new email", "email to ",
                       "conversation with", "chat with", "thread with", "text conversation", "look up",
                       "i wanna talk to", "i want to talk to", "i wanna text", "i want to text"]
        if phrases.contains(where: { joined.hasPrefix($0) || joined.hasPrefix("write " + $0) }) { return true }
        // "Actually I wanna talk to David — open up a text message with Dave":
        // a change of recipient buried mid-sentence is still a command, not
        // something to text the current thread (observed live).
        let anywhere = ["open a conversation with", "open up a conversation with", "open a text message with",
                        "open up a text message with", "open a text with", "open up a text with",
                        "open a message with", "open up a message with", "switch to the conversation with"]
        return anywhere.contains { joined.contains($0) }
    }

    private func draftGmail(gist: String, compose: GmailDrafter.Compose, apiKey: String) {
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = compose.body.isEmpty ? "Writing it…" : "Rewriting it…"
        panel.state.errorText = nil
        remote.broadcast("STATUS \(panel.state.answer)")
        ActivityLog.recordAction("gmail-draft", ["revision": compose.body.isEmpty ? "no" : "yes"])

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            let claude = AnthropicService(apiKey: apiKey)
            let message: String
            var ok = false
            do {
                let draft = try await GmailDrafter.write(gist: gist, compose: compose,
                                                         senderName: NSFullUserName(), claude: claude)
                guard id == requestID else { return }
                // Gmail is web content: `writeTextInBackground` would return
                // `.unsupportedTarget`, so the compose is filled via in-page
                // insertText (the existing path) rather than an AX value set.
                if GmailDrafter.fill(draft, replaceSubject: compose.subject.isEmpty) {
                    ok = true
                    // Still working on it — keep the compose in dictation
                    // mode another ten minutes from now, not from when it opened.
                    gmailDraftOpenedAt = Date()
                    let words = draft.body.split(whereSeparator: { $0.isWhitespace }).count
                    message = "Drafted \(words) words — read it over, then say “send it”, or tell me what to change."
                } else {
                    message = "Wrote it, but couldn't type into the compose window — is it still open?"
                }
            } catch {
                message = "Couldn't write that: \(error.localizedDescription)"
            }
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(ok ? .status : .error, message)
            remote.broadcast("STATUS \(message)")
        }
    }

    private func sendOpenDraft() {
        let gmail = gmailDraftOpenedAt ?? .distantPast
        let messages = messagesDraftOpenedAt ?? .distantPast
        if messages > gmail, Date().timeIntervalSince(messages) < 10 * 60 {
            sendOpenMessagesDraft()
        } else {
            sendOpenGmailDraft()
        }
    }

    /// Empties the compose box of the open Messages thread — in the
    /// background where possible — and forgets the draft, so the next thing
    /// said is written fresh rather than as a revision of the erased text.
    private func eraseOpenMessagesDraft() {
        guard MessagesActions.openConversation() != nil else {
            let message = "The conversation isn't open in Messages any more."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.error, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        let background = MessagesActions.writeIntoOpenConversationInBackground("")
        if background.needsFallback {
            log.notice("messages erase: background write \(String(describing: background), privacy: .public) — falling back to focus-and-type")
        }
        let ok = background.landed || MessagesActions.typeIntoOpenConversation("")
        ActivityLog.recordAction("messages-draft-erase", ["via": background.landed ? "background" : "foreground",
                                                          "result": String(describing: background), "ok": ok ? "yes" : "no"])
        let message: String
        if ok {
            messagesDraftText = nil
            messagesDraftOpenedAt = Date() // still talking to this thread
            message = background == .suspectedNoop ? "Already empty — tell me what to say." : "Erased — tell me what to say instead."
        } else {
            message = "Couldn't clear the message box in Messages."
        }
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(ok ? .status : .error, message)
        remote.broadcast("STATUS \(message)")
    }

    /// "Undo that": pops the last background write off `WriteUndoStack` and
    /// puts the previous text back through the same no-focus path, then
    /// confirms on the panel/phone and out loud, with the ring on the field.
    private func undoLastWrite() {
        synthesizer.stopSpeaking(at: .immediate)
        let target = WriteUndoStack.shared.last?.target
        let outcome = WriteUndoStack.shared.undoLast()
        let message = outcome.message
        var details: [String: String] = ["ok": outcome.ok ? "yes" : "no", "remaining": String(WriteUndoStack.shared.count)]
        if case .restored(let label, _, let forced) = outcome {
            details["label"] = label
            details["forced"] = forced ? "yes" : "no"
            if let frame = target?.frame { ring.show(over: frame, duration: 2.5) }
            // The compose box is the draft again — whatever it now holds is
            // what "make it shorter" / "send it" act on.
            if messagesDraftOpenedAt != nil {
                messagesDraftText = MessagesActions.currentComposeText()
                messagesDraftOpenedAt = Date()
            }
        }
        ActivityLog.recordAction("write-undo", details)
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(outcome.ok ? .status : .error, message)
        remote.broadcast("STATUS \(message)")
        toast.show(message, icon: outcome.ok ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle.fill",
                   tint: outcome.ok ? .cyan : .orange)
        if !panel.state.textOnlyMode { speak(message) }
    }

    /// "Undo that" said in the same breath as the dictation, so the sentence
    /// is still only the live preview in the compose box (the ghost handle
    /// has already been consumed by the drafter): take it back out.
    private func undoPreviewedDraft() {
        let background = MessagesActions.writeIntoOpenConversationInBackground("")
        let ok = background.landed || MessagesActions.typeIntoOpenConversation("")
        if ok { confirmPreviewUndone() } else {
            let message = "Couldn't take the preview back out of Messages."
            ActivityLog.recordAction("write-undo", ["ok": "no", "preview": "yes", "result": String(describing: background)])
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.error, message)
            remote.broadcast("STATUS \(message)")
        }
    }

    /// The preview is gone (cleared by the caller); confirm like a real undo
    /// and keep the thread in dictation mode for the next sentence.
    private func confirmPreviewUndone() {
        synthesizer.stopSpeaking(at: .immediate)
        let name = MessagesActions.openConversation()
        let message = "Undone — took back what I'd started writing\(name.map { " to \($0)" } ?? "")."
        ActivityLog.recordAction("write-undo", ["ok": "yes", "preview": "yes", "remaining": String(WriteUndoStack.shared.count)])
        if let frame = MessagesActions.composeFrame() { ring.show(over: frame, duration: 2.5) }
        messagesDraftText = nil
        if messagesDraftOpenedAt != nil { messagesDraftOpenedAt = Date() }
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(.status, message)
        remote.broadcast("STATUS \(message)")
        toast.show(message, icon: "arrow.uturn.backward.circle.fill", tint: .cyan)
        if !panel.state.textOnlyMode { speak(message) }
    }

    private func sendOpenMessagesDraft() {
        guard messagesDraftText != nil, MessagesActions.openConversation() != nil else {
            let message = "Nothing typed in Messages yet — tell me what to say first."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        panel.state.status = .thinking
        MessagesActions.sendTyped { [weak self] message, ok in
            guard let self else { return }
            if ok { self.messagesDraftOpenedAt = nil; self.messagesDraftText = nil }
            self.panel.state.status = .answering
            self.panel.state.answer = message
            self.panel.state.logTalk(ok ? .status : .error, message)
            self.remote.broadcast("STATUS \(message)")
            self.toast.show(message,
                            icon: ok ? "paperplane.fill" : "exclamationmark.triangle.fill",
                            tint: ok ? .green : .orange)
        }
    }

    /// `previewed`: the raw words are already showing in the compose box as a
    /// live preview — they are *not* an existing draft to revise, and Claude's
    /// text simply takes their place.
    // MARK: - Study site editing

    /// "Publish it", "push that", "deploy the site" — commit and push the
    /// study site. Only consulted when the site is open in a browser.
    private static func isPublishIt(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["ok", "okay", "looks", "good", "great", "and", "now", "please", "then", "just",
                                    "can", "could", "you", "let's", "lets", "hey", "clicky", "go", "ahead", "alright"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        guard let verb = words.first, ["publish", "deploy", "push"].contains(verb), words.count <= 6 else { return false }
        let filler: Set<String> = ["it", "that", "this", "the", "site", "page", "edit", "edits", "change", "changes",
                                   "now", "please", "up", "out", "live", "to", "prod", "production", "github"]
        return words.dropFirst().allSatisfy { filler.contains($0) }
    }

    /// A question to answer beside the box, as opposed to an instruction to
    /// change it. Explicit edit verbs anywhere win ("explain … and put it in
    /// the box" is an edit); otherwise a question opener is a question.
    static func isQuestionAboutBox(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let editVerbs: Set<String> = ["replace", "change", "rewrite", "reword", "rephrase", "add", "append", "insert",
                                      "put", "write", "delete", "remove", "shorten", "expand", "fix", "update", "swap",
                                      "make", "turn", "edit", "correct"]
        if words.contains(where: { editVerbs.contains($0) }) { return false }
        let leadIns: Set<String> = ["hey", "clicky", "ok", "okay", "so", "um", "uh", "can", "could", "would", "you",
                                    "please", "quick", "question", "i", "have", "a", "wanted", "to", "ask", "just"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        guard let first = words.first else { return false }
        let openers: Set<String> = ["what", "what's", "whats", "why", "how", "when", "where", "who", "which", "is", "are",
                                    "does", "do", "did", "explain", "tell", "describe", "walk", "help", "clarify",
                                    "summarize", "summarise", "define", "compare", "should", "will", "would", "can"]
        if openers.contains(first) || utterance.hasSuffix("?") { return true }
        // "It's talking about TCP — can you explain to me and use an analogy":
        // the ask comes after some scene-setting. With no edit verb present,
        // an explaining verb anywhere makes it a question.
        let asks: Set<String> = ["explain", "clarify", "summarize", "summarise", "define", "describe", "elaborate"]
        return words.contains(where: { asks.contains($0) })
    }

    private static func isDoneEditing(_ utterance: String) -> Bool {
        let joined = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return ["done editing", "finish editing", "finished editing", "stop editing", "close the editor",
                "exit edit mode", "leave edit mode", "i'm done", "im done", "that's done", "thats done"]
            .contains { joined.hasSuffix($0) || joined == $0 }
    }

    /// Rewrites the box in edit mode per the spoken instruction: Claude
    /// produces the new content, which lands in the live page (so it shows
    /// on the other screen at once) and in the HTML file on disk (the copy
    /// that persists). Focus never leaves the app the user is in.
    private func editSiteBox(_ context: SiteEditActions.Context, instruction: String, apiKey: String) {
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = "Editing that box…"
        panel.state.errorText = nil
        remote.broadcast("STATUS \(panel.state.answer)")
        ActivityLog.recordAction("site-edit", ["box": context.boxID, "text": instruction])
        guard let box = SiteEditActions.box(context.boxID) else {
            busy = false
            finishSiteEdit("I see a box in edit mode but can't read it — turn on “Allow JavaScript from Apple Events” "
                           + "in the browser's Develop menu, then try again.", ok: false)
            return
        }
        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            var message: String
            var ok = false
            do {
                let result = try await SiteEditDrafter.rewrite(box: box, instruction: instruction,
                                                               claude: AnthropicService(apiKey: apiKey))
                guard id == requestID else { return }
                let onPage = SiteEditActions.setBoxOnPage(box.id, html: result.html)
                try SiteEditActions.writeBoxToFile(box.id, html: result.html, in: context.file)
                ok = true
                ActivityLog.recordAction("site-edit-applied", ["box": box.id, "page": onPage ? "yes" : "no"])
                message = result.summary
                    + (onPage ? "" : " Saved to the file, but the page didn't update — reload to see it.")
                    + " Keep going, or say “publish it”."
            } catch {
                message = "Couldn't make that edit: \(error.localizedDescription)"
            }
            finishSiteEdit(message, ok: ok)
        }
    }

    private func publishSite() {
        busy = true
        panel.state.status = .thinking
        panel.state.answer = "Publishing…"
        remote.broadcast("STATUS Publishing…")
        ActivityLog.recordAction("site-publish")
        Task {
            defer { busy = false }
            // Publish the working copy the open page came from.
            let repo = SiteEditActions.editContext().map { SiteEditActions.repo(containing: $0.file) } ?? SiteEditActions.repoURL
            let result = await SiteEditActions.publish(repo: repo)
            ActivityLog.recordAction("site-publish-done", ["ok": result.ok ? "yes" : "no"])
            finishSiteEdit(result.message, ok: result.ok)
            toast.show(result.message, icon: result.ok ? "arrow.up.circle.fill" : "exclamationmark.triangle.fill",
                       tint: result.ok ? .green : .orange)
        }
    }

    private func finishSiteEdit(_ message: String, ok: Bool) {
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(ok ? .status : .error, message)
        remote.broadcast("STATUS \(message)")
    }

    private func draftMessage(gist: String, recipient: String, apiKey: String, previewed: Bool = false) {
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        // What's really in the compose box counts as the draft — text left
        // there from before Clicky opened this thread included — so "erase
        // that" / "make it shorter" have something to act on.
        let currentDraft = previewed ? nil : (messagesDraftText ?? MessagesActions.currentComposeText())
        panel.state.status = .thinking
        panel.state.answer = currentDraft == nil ? "Writing it…" : "Rewriting it…"
        panel.state.errorText = nil
        remote.broadcast("STATUS \(panel.state.answer)")
        ActivityLog.recordAction("messages-draft", ["revision": currentDraft == nil ? "no" : "yes", "previewed": previewed ? "yes" : "no"])

        requestID += 1
        let id = requestID
        let transcript = MessagesActions.visibleTranscript()
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            let claude = AnthropicService(apiKey: apiKey)
            let message: String
            var ok = false
            do {
                let outcome = try await MessagesDrafter.write(gist: gist, recipient: recipient, transcript: transcript,
                                                              currentDraft: currentDraft,
                                                              senderName: NSFullUserName(), claude: claude)
                guard id == requestID else { return }
                guard case .write(let text) = outcome else {
                    if outcome == .undo {
                        // "…how you're doing — actually, undo that" in one
                        // breath: the sentence was only ever previewed, so
                        // there is no landed write to pop; the preview is
                        // what goes (observed live).
                        if previewed { undoPreviewedDraft() } else { undoLastWrite() }
                    } else {
                        eraseOpenMessagesDraft()
                    }
                    return
                }
                // Prefer writing into the compose box without taking focus
                // from whatever the user is working in; only activate
                // Messages (focus-and-return path) if that verifiably fails.
                let background = MessagesActions.writeIntoOpenConversationInBackground(text)
                if background.needsFallback {
                    log.notice("messages draft: background write \(String(describing: background), privacy: .public) — falling back to focus-and-type")
                }
                ActivityLog.recordAction("messages-draft-insert", ["via": background.landed ? "background" : "foreground",
                                                                   "result": String(describing: background)])
                if background.landed || MessagesActions.typeIntoOpenConversation(text) {
                    ok = true
                    messagesDraftText = text
                    messagesDraftOpenedAt = Date()
                    message = background == .suspectedNoop
                        ? "It already says “\(text)” — say “send it”, or tell me what to change."
                        : "“\(text)” — say “send it”, or tell me what to change."
                } else {
                    message = "Wrote it, but the conversation isn't open in Messages any more."
                }
            } catch {
                message = "Couldn't write that: \(error.localizedDescription)"
            }
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(ok ? .status : .error, message)
            remote.broadcast("STATUS \(message)")
        }
    }

    private func sendOpenGmailDraft() {
        guard let opened = gmailDraftOpenedAt, Date().timeIntervalSince(opened) < 10 * 60 else {
            let message = "No Gmail draft from me to send — say “email that to someone” first."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        panel.state.status = .thinking
        GmailActions.send { [weak self] message, ok in
            guard let self else { return }
            if ok { self.gmailDraftOpenedAt = nil }
            self.panel.state.status = .answering
            self.panel.state.answer = message
            self.panel.state.logTalk(ok ? .status : .error, message)
            self.remote.broadcast("STATUS \(message)")
            self.toast.show(message,
                            icon: ok ? "paperplane.fill" : "exclamationmark.triangle.fill",
                            tint: ok ? .green : .orange)
        }
    }

    /// "Write an email to X" — a blank draft, addressed, nothing sent, so no
    /// confirmation needed; the user is about to type into it anyway.
    private func composeGmail(to recipient: String) async -> String? {
        let only: ContactsService.Match
        switch await gmailRecipient(named: recipient) {
        case .success(let match): only = match
        case .failure(let reason): return reason.message
        }
        GmailActions.composeTo(only.email, body: "")
        gmailDraftOpenedAt = Date()
        gmailDraftRecipient = only.display
        let note = "New email to \(only.display) is open in Gmail — write it, then say “send it”."
        panel.state.answer = note
        panel.state.logTalk(.status, note)
        return nil
    }

    private struct LookupFailure: Error { let message: String }

    private func gmailRecipient(named recipient: String) async -> Result<ContactsService.Match, LookupFailure> {
        let contacts = ContactsService(auth: googleAuth)
        var matches: [ContactsService.Match]
        do {
            matches = try await contacts.search(recipient)
        } catch {
            return .failure(.init(message: "Couldn't look up \(recipient): \(error.localizedDescription)"))
        }
        if matches.isEmpty {
            do {
                matches = try await MacContactsService.emails(for: recipient)
            } catch {
                return .failure(.init(message: "Couldn't look up \(recipient): \(error.localizedDescription)"))
            }
        }
        guard let only = matches.first, matches.count == 1 else {
            if matches.isEmpty {
                return .failure(.init(message: "No contact with an email matching “\(recipient)”. Try their full name or email address."))
            }
            let list = matches.prefix(6).map { "• \($0.display)" }.joined(separator: "\n")
            return .failure(.init(message: "\(matches.count) contacts match “\(recipient)”:\n\(list)\n\n"
                 + "Say the full name or the email address."))
        }
        return .success(only)
    }

    private func sendViaWhatsApp(recipient: String, body: String, screen: NSScreen) async -> String? {
        guard await confirmSend(to: recipient, via: "WhatsApp", body: body, screen: screen) else {
            return "Cancelled — nothing was sent."
        }
        // Typed but not sent: WhatsApp's own Send stays a human click, which
        // matches how the rest of the WhatsApp pad already behaves.
        WhatsAppActions.openChat(named: recipient, status: { [weak self] message, ok in
            guard !ok else { return }
            self?.panel.state.answer = message
        }, then: { [weak self] in
            WhatsAppActions.typeMessage(body) { message, _ in
                self?.panel.state.answer = message
            }
        })
        return nil
    }

    /// The preview. Shows who it resolved to and the opening of what's about
    /// to be sent, so "that" is never ambiguous at the moment it matters.
    private func confirmSend(to recipient: String, via app: String,
                             body: String, screen: NSScreen) async -> Bool {
        let preview = body.count > 220 ? String(body.prefix(220)) + "…" : body
        return await requestConfirm(
            question: "Send to \(recipient) in \(app)?\n\n\(preview)",
            screen: screen
        )
    }

    // MARK: - Drive cleanup (⌥⌘D)    // MARK: - Drive cleanup (⌥⌘D)

    /// Inventory → flag → review → trash. The first three stages never write
    /// anything: the only call that changes Drive is `drive.trash`, and it runs
    /// only from `trashSelectedDriveFiles`, behind the review window's button
    /// and its confirmation.
    private func beginDriveCleanup() {
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            driveCleanup.state.phase = .failed("No Anthropic API key saved — add one before running a cleanup.")
            driveCleanup.show()
            return
        }
        // A second ⌥⌘D while a scan is running just brings the window back.
        if driveCleanupTask != nil {
            driveCleanup.show()
            return
        }

        let state = driveCleanup.state
        state.phase = .scanning("Listing your Drive…")
        state.scannedCount = 0
        state.candidates = []
        state.selection = []
        state.onCancel = { [weak self] in self?.driveCleanup.close() }
        // Closing the window by any route stops the scan — the Cancel button,
        // the red close button and ⌘W all land here.
        driveCleanup.onClose = { [weak self] in
            self?.driveCleanupTask?.cancel()
            self?.driveCleanupTask = nil
        }
        state.onTrash = { [weak self] in self?.trashSelectedDriveFiles() }
        driveCleanup.show()

        driveCleanupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.driveCleanupTask = nil }
            let drive = DriveService(auth: googleAuth)
            do {
                let files = try await drive.inventory { count in
                    state.scannedCount = count
                    state.phase = .scanning("Listing your Drive… \(count) files so far")
                }
                try Task.checkCancellation()
                state.phase = .scanning("Looking for cleanup candidates…")
                let plan = try await DriveCleanupPlanner.plan(
                    files: files, drive: drive, apiKey: apiKey
                ) { message in
                    state.phase = .scanning(message)
                }
                try Task.checkCancellation()
                state.candidates = plan.candidates
                state.signalledCount = plan.signalledCount
                // Claude's flags are the starting selection, not the decision —
                // every row is visible and tickable either way.
                state.selection = Set(plan.candidates.filter(\.flagged).map(\.id))
                state.phase = .review
            } catch is CancellationError {
                return
            } catch {
                state.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The one place in the cleanup flow that writes to Drive. Trash only —
    /// `DriveService` has no permanent-delete call to reach for.
    private func trashSelectedDriveFiles() {
        let state = driveCleanup.state
        let targets = state.selectedCandidates
        guard !targets.isEmpty else { return }

        driveCleanupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.driveCleanupTask = nil }
            let drive = DriveService(auth: googleAuth)
            var trashed = 0
            var failed = 0
            var bytes: Int64 = 0
            for (index, candidate) in targets.enumerated() {
                state.phase = .trashing(done: index, total: targets.count)
                do {
                    try await drive.trash(id: candidate.file.id)
                    trashed += 1
                    bytes += candidate.file.effectiveBytes
                    ActivityLog.recordAction("drive-cleanup-trash", ["name": candidate.file.name])
                } catch {
                    failed += 1
                    log.error("trashing \(candidate.file.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            state.phase = .finished(trashed: trashed, failed: failed, bytes: bytes)
            self.toast.show(
                "Moved \(trashed) file\(trashed == 1 ? "" : "s") to Drive's trash",
                icon: "trash",
                tint: failed > 0 ? .orange : .green
            )
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

    /// Reads the current answer aloud on tap of the "Read aloud" button —
    /// works regardless of `textOnlyMode`, so text-only users can still hear
    /// a specific reply on demand.
    private func replayAnswer() {
        guard !panel.state.answer.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speak(panel.state.answer)
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
