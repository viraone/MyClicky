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
    private let hud = HUDController()
    private let remote = RemoteControlService()
    private let whatsappUnread = WhatsAppUnreadWatcher()
    private let gmailUnread = GmailUnreadWatcher()
    private let captureFileWatcher = CaptureFileWatcher()
    private let driveCleanup = DriveCleanupWindowController()
    private let breakCoach = BreakCoach()
    /// The passage a copy verb last put on the clipboard — what "that" means
    /// in "text that to Noah". Kept apart from `NSPasteboard.general` on
    /// purpose: the system clipboard is shared with every app on the Mac and
    /// with Peeky's own paste-based typing, so it can change out from under
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
    /// Set when "tell the terminal …" typed a line at a prompt and stopped
    /// short of Return: "run it" runs it, "erase that" / "undo that" take it
    /// back, for ten minutes.
    private var terminalDraftOpenedAt: Date?
    private var terminalTarget: TerminalLineTarget?
    /// Set when TALK typed into an AI chat site's prompt box (AI Studio,
    /// ChatGPT…): "send it" runs it, "erase that" / "undo that" take it back.
    private var chatSiteDraftOpenedAt: Date?
    private var chatSiteTarget: ChatSiteTarget?
    /// Set when "open AI Studio" had to load the page fresh, so the first
    /// dictation waits for it rather than failing on an empty tab.
    private var chatSiteOpenedFreshAt: Date?
    /// The in-flight inventory/flagging pass, so Cancel and a second ⌥⌘D can
    /// stop it rather than stacking a second scan on top.
    private var driveCleanupTask: Task<Void, Never>?

    private var activeScreen: NSScreen?
    /// The display the user is working on, decided at the moment it's needed:
    /// wherever Peeky's panel currently sits — they put it there, and they can
    /// drag it to another screen mid-recording. `activeScreen` is only where
    /// the panel was opened and goes stale the moment it's moved.
    private var workingScreen: NSScreen {
        panel.screen ?? activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private var busy = false
    /// The Claude request currently in flight, so Stop can cancel it.
    private var currentTask: Task<Void, Never>?
    private var siteSaveTask: Task<Void, Never>?
    /// Bumped on every new request/stop; stale tasks compare against it
    /// before touching panel state.
    private var requestID = 0
    private let speechDelegate = SpeechDelegate()
    /// Called when the iOS remote asks to start a region capture (key "5").
    var onCaptureRequest: (() -> Void)?

    /// Shows a fresh region capture in the panel's Capture + Dictate tab and
    /// puts it on the clipboard alongside the latest dictation. Also the
    /// landing point for files added via the + menu, which set `kind`.
    func showCapture(image: NSImage, url: URL, kind: AssistantState.AttachmentKind = .capture) {
        if kind == .capture {
            // A region grab: the mouse is where the drag ended, so that's the
            // display the capture came from. Park the preview in its top-right
            // corner rather than wherever the panel last sat.
            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
            if let screen {
                activeScreen = screen
                if panel.state.status != .thinking {
                    panel.state.status = .idle
                    panel.state.errorText = nil
                }
                panel.showInCorner(on: screen)
            }
        } else {
            showPanel()
        }
        panel.state.tab = .captureDictate
        panel.state.attachmentKind = kind
        panel.state.captureImage = image
        panel.state.captureURL = url
        panel.state.editedCaptureImage = nil
        panel.state.clipboardChoice = .edited
        copyPairToClipboard()
        // Only pixels can be "edited in Preview and reloaded" — a folder or
        // a PDF changing on disk means nothing to the icon we show for it.
        if kind == .file { captureFileWatcher.stop() } else { captureFileWatcher.start(url: url) }
    }

    /// The + menu's "Files and folders": a native picker, then the choice
    /// goes through `showCapture` so it previews, copies, and opens on click
    /// like any capture. The panel is non-activating, so the app has to be
    /// brought forward for the picker to take keyboard focus.
    private func attachFileFromMac() {
        let open = NSOpenPanel()
        open.title = "Add to Peeky"
        open.message = "Choose a file or folder to show in the capture preview."
        open.prompt = "Add"
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = false
        open.level = .floating
        // Start in the résumé folder on the Desktop so the usual attachment
        // is one click away; fall back to the Desktop if it isn't there.
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let resumeFolder = desktop.appendingPathComponent("VIRADETH_RESUME")
        open.directoryURL = FileManager.default.fileExists(atPath: resumeFolder.path) ? resumeFolder : desktop
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let url = open.url, let self else { return }
            self.showAttachment(url: url)
        }
    }

    // MARK: Ask history

    private func rememberAsk(question: String, answer: String) {
        let entry = AskHistoryEntry(question: question, answer: answer, date: Date(),
                                    attachmentNames: panel.state.askAttachments.map(\.name))
        panel.state.askHistory.insert(entry, at: 0)
        if panel.state.askHistory.count > AskHistoryStore.limit {
            panel.state.askHistory.removeLast(panel.state.askHistory.count - AskHistoryStore.limit)
        }
        AskHistoryStore.save(panel.state.askHistory)
    }

    /// A History row was clicked: put that question and answer back on the
    /// Ask tab, as text, without speaking it again.
    private func restoreFromHistory(_ entry: AskHistoryEntry) {
        guard !busy else { return }
        ActivityLog.recordAction("ask-history-open", ["text": entry.question])
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.showingAskHistory = false
        panel.state.tab = .ask
        panel.state.transcript = entry.question
        panel.state.answer = entry.answer
        panel.state.errorText = nil
        panel.state.restoredFromHistory = true
        panel.state.status = .answering
    }

    // MARK: Ask attachments (pictures the question is about)

    /// The Ask tab's + menu: a multi-select image picker.
    private func attachImagesToAsk() {
        let open = NSOpenPanel()
        open.title = "Attach to your question"
        open.message = "Pick up to \(AssistantState.maxAskAttachments) images — Peeky sees them with every question until you remove them."
        open.prompt = "Attach"
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.image]
        open.level = .floating
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let resumeFolder = desktop.appendingPathComponent("VIRADETH_RESUME")
        open.directoryURL = FileManager.default.fileExists(atPath: resumeFolder.path) ? resumeFolder : desktop
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.addAskAttachments(urls: open.urls, via: "picker")
        }
    }

    /// ⌘V or the menu's "Paste image": an image, or image files, on the clipboard.
    private func pasteIntoAsk() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addAskAttachments(urls: urls, via: "paste")
            return
        }
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first {
            addAskAttachments([(image, "Pasted image")], via: "paste")
            return
        }
        hud.report("Nothing on the clipboard to attach.", ok: false)
    }

    private func addAskAttachments(urls: [URL], via: String) {
        var items: [(NSImage, String)] = []
        var skipped: [String] = []
        for url in urls {
            if let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 {
                items.append((image, url.lastPathComponent))
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            hud.report("Only images can be attached — skipped \(skipped.joined(separator: ", ")).", ok: false)
        }
        addAskAttachments(items, via: via)
    }

    private func addAskAttachments(_ items: [(image: NSImage, name: String)], via: String) {
        guard !items.isEmpty else { return }
        let room = AssistantState.maxAskAttachments - panel.state.askAttachments.count
        guard room > 0 else {
            hud.report("That's \(AssistantState.maxAskAttachments) images — remove one to add another.", ok: false)
            return
        }
        let accepted = Array(items.prefix(room))
        panel.state.askAttachments.append(contentsOf: accepted.map {
            AssistantState.AskAttachment(image: $0.image, name: $0.name)
        })
        panel.state.askAttachmentsCollapsed = false
        panel.state.tab = .ask
        ActivityLog.recordAction("ask-attach", ["via": via, "added": "\(accepted.count)",
                                                "total": "\(panel.state.askAttachments.count)"])
        if accepted.count < items.count {
            hud.report("Attached \(accepted.count) — the strip holds \(AssistantState.maxAskAttachments).", ok: false)
        }
    }

    /// JPEGs of the strip, longest side capped so ten pictures don't blow
    /// the request up; nil entries are dropped.
    private func askAttachmentJPEGs() -> [(name: String, jpeg: Data)] {
        panel.state.askAttachments.compactMap { item in
            Self.jpegData(item.image, maxDimension: 1400).map { (item.name, $0) }
        }
    }

    private static func jpegData(_ image: NSImage, maxDimension: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        var source = cg
        if scale < 1 {
            let nw = Int(w * scale), nh = Int(h * scale)
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                if let scaled = ctx.makeImage() { source = scaled }
            }
        }
        let rep = NSBitmapImageRep(cgImage: source)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    func showAttachment(url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDirectory, let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 {
            ActivityLog.recordAction("attach", ["kind": "image", "name": url.lastPathComponent])
            showCapture(image: image, url: url, kind: .image)
        } else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 256, height: 256)
            ActivityLog.recordAction("attach", ["kind": isDirectory ? "folder" : "file", "name": url.lastPathComponent])
            showCapture(image: icon, url: url, kind: .file)
        }
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
        panel.state.attachmentKind = .capture
    }

    // MARK: - Peeky Code (questions about a dropped project)

    /// The Code tab's + menu and drop-zone button: pick a folder, or files.
    private func pickCodeProject() {
        let open = NSOpenPanel()
        open.title = "Choose a project"
        open.message = "Pick a project folder (or a few source files). Peeky reads the code and answers questions about it."
        open.prompt = "Open"
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.level = .floating
        open.directoryURL = panel.state.codeProject?.root.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.loadCodeProject(urls: open.urls, via: "picker")
        }
    }

    /// Reads the dropped folder off the main thread and swaps it in. A new
    /// project starts a fresh conversation; the old one was about other code.
    private func loadCodeProject(urls: [URL], via: String) {
        guard !urls.isEmpty else { return }
        let previousRoot = panel.state.codeProject?.root
        panel.state.tab = .code
        panel.state.codeLoading = true
        panel.state.errorText = nil
        Task {
            let project = await Task.detached(priority: .userInitiated) {
                CodeProjectBundler.bundle(urls: urls)
            }.value
            panel.state.codeLoading = false
            guard let project, !project.files.isEmpty else {
                hud.report("No code found there — Peeky reads source and text files, not images or binaries.", ok: false)
                return
            }
            if project.root != previousRoot {
                panel.state.codeLog = []
                panel.state.codeUsage = nil
                panel.state.codeFocusedFile = nil
                panel.state.codeShowingFiles = false
            } else if let focused = panel.state.codeFocusedFile, project.file(at: focused) == nil {
                panel.state.codeFocusedFile = nil
            }
            panel.state.codeProject = project
            var line = "Loaded \(project.name) — \(project.summaryLine)."
            if !project.skippedFolders.isEmpty {
                line += " Skipped \(project.skippedFolders.joined(separator: ", "))."
            }
            if project.truncated {
                line += " Too big to send whole: \(project.skippedFiles.count) files left out — drop a subfolder for those."
            }
            panel.state.logCode(.status, line)
            refreshLiveCost()
            ActivityLog.recordAction("code-project", ["via": via, "files": "\(project.files.count)",
                                                      "tokens": "\(project.estimatedTokens)",
                                                      "truncated": project.truncated ? "1" : "0"])
        }
    }

    /// Re-reads the same folder after the user edited files in their editor.
    /// The bundle bytes change, so the next question re-primes the cache.
    private func reloadCodeProject() {
        guard let project = panel.state.codeProject else { return }
        loadCodeProject(urls: [project.root], via: "reload")
    }

    private func removeCodeProject() {
        panel.state.codeProject = nil
        panel.state.codeUsage = nil
        panel.state.codeLog = []
        panel.state.codeFocusedFile = nil
        panel.state.codeShowingFiles = false
        ActivityLog.recordAction("code-project-remove", [:])
    }

    private var lastCostFetch: Date = .distantPast

    /// Pulls the real month-to-date spend if an Admin key is in Keychain.
    /// Free to call, but throttled: the report only moves once a day.
    private func refreshLiveCost(force: Bool = false) {
        guard let adminKey = KeychainService.anthropicAdminKey(), !adminKey.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastCostFetch) > 60 else { return }
        lastCostFetch = Date()
        Task { [weak self] in
            do {
                let usd = try await AnthropicService.fetchMonthToDateCostUSD(adminKey: adminKey)
                self?.panel.state.codeLiveCostUSD = usd
            } catch {
                log.notice("live cost fetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Dropped on the Code tab: image files become question attachments,
    /// anything else is the project.
    private func dropIntoCode(urls: [URL]) {
        let images = urls.filter { url in
            !((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
        }
        if !images.isEmpty { addCodeImages(urls: images, via: "drop") }
        let rest = urls.filter { !images.contains($0) }
        if !rest.isEmpty { loadCodeProject(urls: rest, via: "drop") }
    }

    private func attachImagesToCode() {
        let open = NSOpenPanel()
        open.title = "Images for your code question"
        open.message = "Screenshots, mockups, error dialogs — up to \(AssistantState.maxCodeImages), sent with every question until removed."
        open.prompt = "Attach"
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.image]
        open.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.addCodeImages(urls: open.urls, via: "picker")
        }
    }

    private func addCodeImages(urls: [URL], via: String) {
        let room = AssistantState.maxCodeImages - panel.state.codeImages.count
        guard room > 0 else {
            hud.report("That's \(AssistantState.maxCodeImages) images — remove one to add another.", ok: false)
            return
        }
        var added = 0
        for url in urls.prefix(room) {
            if let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 {
                panel.state.codeImages.append(AssistantState.AskAttachment(image: image, name: url.lastPathComponent))
                added += 1
            }
        }
        if added > 0 {
            panel.state.logCode(.status, "Attached \(added) image\(added == 1 ? "" : "s") — Peeky sees them with each question.")
        }
        ActivityLog.recordAction("code-attach-image", ["via": via, "added": "\(added)"])
    }

    private func handleCodeQuestion(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        guard let project = panel.state.codeProject else {
            panel.state.logCode(.error, "Drop a project folder first — then ask away.")
            return
        }
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            panel.state.logCode(.error, "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)")
            return
        }
        ActivityLog.recordAction("code-ask", ["text": question, "files": "\(project.files.count)"])
        let history = panel.state.codeHistory
        let focusedFile = panel.state.codeFocusedFile
        let images = panel.state.codeImages.compactMap { item in
            Self.jpegData(item.image, maxDimension: 1400).map { (name: item.name, jpeg: $0) }
        }
        panel.state.logCode(.question, question)
        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        panel.state.status = .thinking
        panel.state.errorText = nil

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer {
                if id == requestID {
                    busy = false
                    currentTask = nil
                    if talkSession { afterTalkSegment() }
                }
            }
            do {
                let claude = AnthropicService(apiKey: apiKey)
                let answer = try await claude.askAboutCode(question: question, project: project,
                                                           focusedFile: focusedFile, images: images,
                                                           history: history) { [weak self] status in
                    guard let self, id == self.requestID else { return }
                    self.panel.state.logCode(.status, status)
                }
                try Task.checkCancellation()
                guard id == requestID else { return }
                panel.state.status = .answering
                panel.state.codeUsage = answer.usage
                panel.state.logCode(.answer, answer.text)
                if let usage = answer.usage {
                    panel.state.codeSpentUSD += usage.costUSD
                    refreshLiveCost()
                    ActivityLog.recordAction("code-answer", ["cache_read": "\(usage.cacheRead)",
                                                             "cache_write": "\(usage.cacheWrite)",
                                                             "input": "\(usage.input)", "output": "\(usage.output)"])
                }
            } catch {
                guard id == requestID, !Task.isCancelled else { return }
                panel.state.status = .idle
                panel.state.logCode(.error, error.localizedDescription)
            }
        }
    }
    /// What the current listening session will do with what it hears.
    private enum RecordKind { case ask, dictate, talk, code }
    private var recordKind: RecordKind = .ask
    /// The app a Talk command should act on, captured when recording starts —
    /// Peeky's own panel is non-activating, so this stays the real target.
    private var talkTargetApp: NSRunningApplication?
    /// Talk streaming: while a Talk recording is still running, every pause
    /// hands the words said since the last pause to the planner, so "copy
    /// from import to the closing script tag … (pause) … open Dino Dad's
    /// conversation … (pause) … send that to Dino Dad … STOP" runs as three
    /// commands, each starting the moment the user stops talking.
    private var talkStreaming = false {
        didSet { panel.state.streaming = talkStreaming }
    }
    private var streamQuestionsOnly = false
    private var streamTranscript = ""
    private var streamPauseTask: Task<Void, Never>?
    /// True from the first word of a Talk session until its last segment has
    /// run — the copied preview survives across segments while this is set.
    private var talkSession = false
    /// A question that came from the phone's ASK key is in flight: when its
    /// answer lands, the panel is brought to the full Ask card even if
    /// something shrank it meanwhile.
    private var phoneAskInFlight = false
    /// The Mac panel is on Peeky Code with a project loaded — the phone's ASK
    /// is a question about that code, not about the screen.
    private var codeTabPinned: Bool { panel.state.tab == .code && panel.state.codeProject != nil }
    /// Words already run as segments this session, in transcript order.
    private var talkDispatched: [String] = []
    /// Everything the last Talk session ran, kept after it ends: the phone
    /// sends its whole transcript once more when TALK is stopped, and if
    /// streaming already finished by then that must not run again as one
    /// giant command (observed live: it replayed "open AI Studio … send it"
    /// through the planner and sat on the Talk tab while an ASK waited).
    private var talkRanWords: [String] = []
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
        panel.state.onDo = { [weak self] text in
            self?.handleDo(text, targetApp: NSWorkspace.shared.frontmostApplication)
        }
        panel.state.onStop = { [weak self] in self?.stop() }
        panel.state.onCopyAgain = { [weak self] in self?.copyPairToClipboard() }
        panel.state.onDismissCapture = { [weak self] in self?.dismissCapture() }
        panel.state.onAttachFile = { [weak self] in self?.attachFileFromMac() }
        panel.state.onAttachToAsk = { [weak self] in self?.attachImagesToAsk() }
        panel.state.askHistory = AskHistoryStore.load()
        panel.state.onRestoreHistory = { [weak self] entry in self?.restoreFromHistory(entry) }
        panel.state.onDeleteHistory = { [weak self] entry in
            guard let self else { return }
            self.panel.state.askHistory.removeAll { $0.id == entry.id }
            AskHistoryStore.save(self.panel.state.askHistory)
        }
        panel.state.onClearHistory = { [weak self] in
            guard let self else { return }
            self.panel.state.askHistory = []
            AskHistoryStore.save([])
            ActivityLog.recordAction("ask-history-clear", [:])
        }
        panel.state.onDropIntoAsk = { [weak self] urls in self?.addAskAttachments(urls: urls, via: "drop") }
        panel.state.onDropIntoCode = { [weak self] urls in self?.dropIntoCode(urls: urls) }
        panel.state.onAttachCodeImages = { [weak self] in self?.attachImagesToCode() }
        panel.state.onAttachCodeProject = { [weak self] in self?.pickCodeProject() }
        panel.state.onReloadCodeProject = { [weak self] in self?.reloadCodeProject() }
        panel.state.onRemoveCodeProject = { [weak self] in self?.removeCodeProject() }
        panel.state.onAskCode = { [weak self] text in self?.handleCodeQuestion(text) }
        panel.state.onPasteIntoAsk = { [weak self] in self?.pasteIntoAsk() }
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

        // Peeky Remote (iOS app) commands over the local network.
        remote.onShow = { [weak self] in
            guard let self else { return }
            // A finished TALK leaves `talkStreaming` set (holding its green
            // "Done."); that must not pin the phone's next ASK to the Talk tab.
            if !self.busy, !self.talkStreaming || self.streamQuestionsOnly, !self.codeTabPinned { self.panel.state.tab = .ask }
            self.showPanel()
        }
        remote.onListen = { [weak self] in
            guard let self else { return }
            // Phone ASK: open the full card while the user is still speaking,
            // so the answer never lands in a corner dot or the one-line strip.
            // The phone has its own TALK key, so a LISTEN is always a question:
            // a Talk that is still finishing (or holding its "Done.") hands the
            // panel over rather than pinning the Ask to the Talk tab.
            if self.panel.state.tab == .talk {
                if self.busy || self.talkStreaming { self.abandonWork() }
                self.panel.state.tab = .ask
            }
            // On Peeky Code with a project up, the question is about the code:
            // same pause-to-answer streaming as Ask, routed to the code flow.
            if self.codeTabPinned {
                self.showPanel(listening: true, full: true)
                self.beginTalkStreaming(questionsOnly: true)
                return
            }
            let asking = self.panel.state.tab == .ask
            if asking { self.phoneAskInFlight = true }
            self.showPanel(listening: true, full: asking)
            if asking { self.beginTalkStreaming(questionsOnly: true) }
        }
        remote.onListenTalk = { [weak self] in
            guard let self else { return }
            self.talkTargetApp = NSWorkspace.shared.frontmostApplication
            // Phone-driven: if the panel was closed, it comes back as the thin
            // strip at the bottom of the work screen — a status readout, out
            // of the way. If it's already up, it stays exactly as the user
            // has it (size, spot, and all); only the tab changes.
            let wasHidden = !self.panel.isVisible
            self.showPanel(listening: true)
            if wasHidden, let screen = self.activeScreen { self.panel.showAsStrip(on: screen) }
            // The phone has its own ASK key, so TALK always means "do it" —
            // whatever tab the Mac panel was left on. (Deferring to the Ask
            // tab here turned "open Messages" into a question three times in
            // a row after an ASK had parked the panel there.)
            self.phoneAskInFlight = false
            self.panel.state.tab = .talk
            self.beginTalkStreaming(questionsOnly: false)
        }
        // Streaming silence is tracked independently of the answer UI state.
        remote.onStop = { [weak self] in self?.stop() }
        remote.onCollapse = { [weak self] in
            guard let self else { return }
            // Enter toggles: collapse if expanded, bring back if collapsed/hidden.
            if self.panel.isVisible && !self.panel.state.collapsed {
                self.panel.minimize()
            } else if self.panel.isVisible {
                if !self.talkStreaming && !self.busy && !self.codeTabPinned { self.panel.state.tab = .ask }
                self.panel.expand()
            } else {
                if !self.talkStreaming && !self.busy && !self.codeTabPinned { self.panel.state.tab = .ask }
                self.showPanel()
            }
        }
        remote.onTab = { [weak self] name in
            guard let self else { return }
            self.showPanel()
            switch name {
            case "DICTATE", "CAPTURE", "CAPTURE_DICTATE": self.panel.state.tab = .captureDictate
            case "CODE": self.panel.state.tab = .code
            // The phone's ASK key sends TAB ASK before it listens. With a
            // project open on Peeky Code, that ask is about the code — stay.
            case "ASK" where self.codeTabPinned: break
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
            self.toast.show("Saving photo to VIRADETH_RESUME…", icon: "photo", tint: .yellow)
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
            // ASK from the phone always reads on the Ask tab, full size — the
            // exceptions are the Mac deliberately parked on Capture + Dictate,
            // or on Peeky Code with a project loaded (the question is about it).
            // A Talk still running would make handleQuestion drop the question
            // on its busy guard; the user's ASK wins.
            if self.busy, !self.streamQuestionsOnly { self.abandonWork() }
            if self.codeTabPinned {
                self.showPanel(full: true)
                self.panel.state.transcript = question
                if self.talkStreaming, self.streamQuestionsOnly {
                    self.finishTalkStreaming(final: question)
                } else {
                    self.handleCodeQuestion(question)
                }
                return
            }
            if self.panel.state.tab != .captureDictate { self.panel.state.tab = .ask }
            self.phoneAskInFlight = true
            self.showPanel(full: true)
            self.panel.state.transcript = question
            if self.talkStreaming, self.streamQuestionsOnly {
                self.finishTalkStreaming(final: question)
                return
            }
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
            // if Peeky's panel itself is/becomes frontmost, the planner would
            // read and act on Peeky's own UI instead of the intended app.
            if self.talkStreaming {
                self.panel.state.transcript = utterance
                self.finishTalkStreaming(final: utterance)
                return
            }
            // The phone's final transcript after streaming already ended:
            // run only what hasn't run, which is usually nothing.
            var utterance = utterance
            let words = Self.words(utterance)
            if let rest = Self.remainder(after: self.talkRanWords, in: words) {
                self.talkRanWords = words
                if rest.isEmpty {
                    ActivityLog.recordAction("talk-final-already-ran", ["text": utterance])
                    return
                }
                utterance = rest.joined(separator: " ")
            } else {
                self.talkRanWords = []
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
             "GMAIL_UNREAD \(self?.gmailUnread.count ?? 0)",
             self?.screensLine() ?? "SCREENS 1 1"]
        }
        remote.onScreen = { [weak self] index in self?.switchScreen(to: index) }
        panel.onScreenChange = { [weak self] _ in
            guard let self else { return }
            self.remote.broadcast(self.screensLine())
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remote.broadcast(self.screensLine())
            }
        }
        whatsappUnread.onChange = { [weak self] count in
            self?.remote.broadcast("WHATSAPP_UNREAD \(count)")
        }
        whatsappUnread.start()
        gmailUnread.onChange = { [weak self] count in
            self?.remote.broadcast("GMAIL_UNREAD \(count)")
        }
        gmailUnread.start()
        siteSaveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if !self.busy { await SiteEditActions.savePendingPageEdit() }
            }
        }
        remote.start()
        ActivityLog.startSampling()
        startBreakCoach()
    }

    /// Brings up the assistant panel without starting local speech capture
    /// (used by the iOS remote, which records on the phone). `full` also
    /// restores the whole card (no dot, no strip, stretched tall) so an
    /// answer asked from the phone is readable the moment it lands.
    private func showPanel(listening: Bool = false, full: Bool = false) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        activeScreen = panel.screen ?? screen
        if panel.state.status != .thinking {
            panel.state.status = listening ? .listening : .idle
            if listening { panel.state.transcript = "" }
            panel.state.errorText = nil
        }
        if full {
            panel.presentFull(near: cursor, on: screen)
        } else {
            panel.show(near: cursor, on: screen)
        }
    }

    /// `SCREENS <count> <current>` — how many displays are attached and which
    /// one (1-based) Peeky is on; 0 when the panel is hidden. The phone's
    /// lever draws itself from this and nothing else.
    private func screensLine() -> String {
        "SCREENS \(NSScreen.screens.count) \(panel.currentScreenIndex ?? 0)"
    }

    /// The phone's screen lever: put Peeky's panel and the pointer on display
    /// `index`, so everything that follows the pointer or the panel — ASK
    /// screenshots, TALK targets, CAPTURE — happens on that screen.
    private func switchScreen(to index: Int) {
        guard let target = panel.move(toScreenIndex: index) else {
            remote.broadcast(screensLine())
            return
        }
        activeScreen = target
        // Warp the pointer to the panel so "the display under the pointer"
        // agrees with the lever. Cocoa's frame is bottom-left; CoreGraphics
        // wants top-left, measured from the primary display's top edge.
        let panelFrame = panel.frame ?? target.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? target.frame.height
        let point = CGPoint(x: panelFrame.midX, y: primaryHeight - panelFrame.maxY - 24)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        ActivityLog.recordAction("screen-switch", ["to": "\(index)"])
        remote.broadcast(screensLine())
    }

    /// Full Ask card for an answer that has just landed — no dot, no strip,
    /// tall — without touching `status`, so the green "Done." stays put.
    private func presentAskAnswerFull() {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        if panel.state.tab != .captureDictate { panel.state.tab = .ask }
        panel.presentFull(near: cursor, on: screen)
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
        case .code: .code
        }
        panel.state.status = .listening
        panel.state.transcript = ""
        panel.state.answer = ""
        panel.state.errorText = nil
        panel.show(near: cursor, on: screen)

        speech.onPartial = { [weak self] text in
            self?.applyPartial(text)
        }
        if kind == .talk || kind == .ask || kind == .code { beginTalkStreaming(questionsOnly: kind != .talk) }

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
        guard panel.state.status == .listening || talkStreaming else { return }
        let kind = recordKind
        let target = talkTargetApp
        recordKind = .ask
        Task {
            let heard = await speech.finish()
            if (kind == .talk || kind == .ask || kind == .code), talkStreaming {
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
            case .code: handleCodeQuestion(heard)
            }
        }
    }

    // MARK: - Talk streaming (run each command at the pause)

    private func beginTalkStreaming(questionsOnly: Bool = false) {
        streamPauseTask?.cancel()
        streamTranscript = ""
        streamQuestionsOnly = questionsOnly
        talkStreaming = true
        talkSession = true
        talkDispatched = []
        talkRanWords = []
        talkQueue = []
        panel.state.copiedPreview = nil
        panel.state.answer = ""
    }

    /// Live transcript from either recognizer. While streaming, a segment may
    /// be running (status thinking/answering) — new words switch the panel
    /// back to listening so the phase shows recording again.
    private func applyPartial(_ text: String) {
        if talkStreaming {
            guard text != streamTranscript else { return }
            streamTranscript = text
            panel.state.transcript = text
            hud.attach(to: panel.screen ?? activeScreen)
            hud.hear(text)
            if !busy {
                synthesizer.stopSpeaking(at: .immediate)
                panel.state.chaining = false
                panel.state.status = .listening
            }
            // Keep receiving and queueing speech even while the previous answer runs.
            talkPaused()
            if !streamQuestionsOnly { streamGhostDraft(text) }
            return
        }
        guard panel.state.status == .listening else { return }
        panel.state.transcript = text
        hud.attach(to: panel.screen ?? activeScreen)
        hud.hear(text)
    }

    /// Streaming dictation insert: while the user is talking to a Messages
    /// thread Peeky opened, the words appear in the compose box as they're
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
        if !pendingConfirms.isEmpty || Self.isSendIt(utterance) || Self.isEraseIt(utterance) || Self.isUndoIt(utterance) || Self.isNeverMind(utterance) || Self.isAppCommand(utterance) || Self.isTerminalCommand(utterance) {
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
        guard talkStreaming else { return }
        streamPauseTask?.cancel()
        let snapshot = streamTranscript
        let grace = streamQuestionsOnly ? 800_000_000 : (dictationGrace(for: snapshot) ?? 800_000_000)
        streamPauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000 + grace)
            guard !Task.isCancelled, let self, self.talkStreaming,
                  self.streamTranscript == snapshot else { return }
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
        if !pendingConfirms.isEmpty || Self.isSendIt(utterance) || Self.isEraseIt(utterance) || Self.isUndoIt(utterance) || Self.isNeverMind(utterance) || Self.isAppCommand(utterance) || Self.isTerminalCommand(utterance) {
            return nil
        }
        let dangling: Set<String> = ["a", "an", "the", "and", "or", "but", "so", "to", "at", "in", "on", "of", "for",
                                     "with", "from", "by", "about", "is", "are", "was", "be", "gonna", "going", "that",
                                     "where", "when", "what", "who", "how", "if", "because", "like", "um", "uh"]
        return dangling.contains(last) ? 3_500_000_000 : 2_000_000_000
    }

    private func dispatchTalkSegment() {
        let words = Self.words(streamTranscript)
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
        if let rest = Self.remainder(after: talkDispatched, in: words) { return rest }
        if !quiet {
            ActivityLog.recordAction("talk-transcript-restarted", ["dispatched": "\(talkDispatched.count)", "now": "\(words.count)"])
        }
        return words
    }

    /// `words` minus the leading `ran` words, or nil when `words` doesn't
    /// start with them (a fresh transcript). The recognizer may revise
    /// earlier words ("open" → "Open,"), so a mostly-matching prefix counts.
    static func remainder(after ran: [String], in words: [String]) -> [String]? {
        guard !ran.isEmpty else { return nil }
        let prefix = ran.map(normalizedWord)
        let current = words.prefix(prefix.count).map(normalizedWord)
        guard current.count == prefix.count else { return nil }
        if current == prefix { return Array(words[prefix.count...]) }
        let agree = zip(current, prefix).filter { $0 == $1 }.count
        return agree * 3 >= prefix.count * 2 ? Array(words[prefix.count...]) : nil
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// STOP: whatever is left after the last dispatched segment runs too.
    private func finishTalkStreaming(final: String) {
        streamPauseTask?.cancel()
        talkStreaming = false
        let words = Self.words(final)
        let rest = pendingTalkWords(in: words).joined(separator: " ")
        let ranSomething = !talkDispatched.isEmpty || !talkQueue.isEmpty || busy
        talkRanWords = words
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
        // live: it read Peeky's own transcript back). Follow focus, unless
        // focus is on Peeky's panel, in which case the last real app stands.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            talkTargetApp = front
        }
        if streamQuestionsOnly {
            if codeTabPinned { handleCodeQuestion(segment) } else { handleQuestion(segment) }
        } else {
            handleDo(segment, targetApp: talkTargetApp)
        }
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
        case .code: .code
        }
        if panel.state.status == .listening || talkStreaming {
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
        // A non-image attachment is copied as the file itself (paste into
        // Finder, Mail, Slack…), not as a picture of its icon.
        if panel.state.attachmentKind == .file, let url = panel.state.captureURL {
            item.setString(url.absoluteString, forType: .fileURL)
        } else if let image, let tiff = image.tiffRepresentation {
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
        // Keep the displayed question current for every input path, including typing.
        panel.state.transcript = question
        if Self.isClickIntent(question) {
            ActivityLog.recordAction("click", ["text": question])
            handleClickCommand(question)
            return
        }
        if Self.isTrashIntent(question), !Self.isEmailIntent(question) {
            if PhotosActions.isFrontmost() {
                ActivityLog.recordAction("trash", ["target": "photos"])
                handlePhotosDeleteCommand()
            } else {
                ActivityLog.recordAction("trash", [:])
                handleTrashCommand()
            }
            return
        }
        ActivityLog.recordAction("ask", ["text": question])
        guard let apiKey = KeychainService.anthropicAPIKey() else {
            panel.state.errorText = "No Anthropic API key found in Keychain.\n\nRun this once in Terminal:\n\(KeychainService.setupCommand)"
            panel.state.status = .idle
            return
        }
        let screen = workingScreen

        busy = true
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil
        panel.state.showingAskHistory = false
        panel.state.restoredFromHistory = false
        // With the study site open, the answer is also rendered in the page
        // (under the box being edited) so it can be read there.
        let siteBox = SiteEditActions.editContext()
        let siteOpen = siteBox != nil || SiteEditActions.siteTabURL() != nil
        if siteOpen { SiteEditActions.showThinking(question) }

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer {
                if id == requestID {
                    busy = false
                    currentTask = nil
                    if talkSession { afterTalkSegment() }
                    if phoneAskInFlight {
                        phoneAskInFlight = false
                        presentAskAnswerFull()
                    }
                }
            }
            do {
                let image = try await capture.captureDisplayJPEG(screen: screen, maxDimension: 1600,
                                                                 excludingOwnWindows: true)
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
                let attachments = askAttachmentJPEGs()
                if !attachments.isEmpty {
                    ActivityLog.recordAction("ask-with-attachments", ["count": "\(attachments.count)"])
                }
                let answer = try await claude.ask(question: question, jpegImage: image, context: context,
                                                  attachments: attachments) { [weak self] status in
                    guard let self, id == self.requestID else { return }
                    self.panel.state.answer = status
                }
                try Task.checkCancellation()
                guard id == requestID else { return }
                panel.state.status = .answering
                panel.state.answer = answer.text
                rememberAsk(question: question, answer: answer.text)
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
        // A confirm card is up: "yes" / "send it" / "no" / "cancel" answers it
        // and is never a new command.
        if let id = pendingConfirms.keys.first, let answer = Self.spokenConfirmAnswer(utterance) {
            ActivityLog.recordAction("confirm-spoken", ["text": utterance, "answer": answer ? "yes" : "no"])
            panel.state.logTalk(.command, utterance)
            takeGhostDraft()?.clear()
            resolveConfirm(id: id, result: answer)
            return
        }
        guard !busy else { return }
        ActivityLog.recordAction("do", ["text": utterance])
        panel.state.logTalk(.command, utterance)
        hud.decide("“\(utterance)”")
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
        // A prompt Peeky typed into an AI chat site is the most recent draft:
        // "send it" / "run it" / "hit enter" runs it; "erase that" clears it.
        if chatSiteDraftIsCurrent {
            if Self.isRunIt(utterance) {
                ghost?.clear()
                submitChatSitePrompt()
                return
            }
            if Self.isEraseIt(utterance) {
                ghost?.clear()
                eraseChatSitePrompt()
                return
            }
        }
        // A line Peeky typed at a terminal prompt is the most recent draft:
        // "run it" / "hit enter" presses Return (behind a confirm); "erase
        // that" backspaces it out.
        if terminalDraftIsCurrent {
            if Self.isRunIt(utterance) {
                ghost?.clear()
                Task { @MainActor [weak self] in await self?.runOpenTerminalLine() }
                return
            }
            if Self.isEraseIt(utterance) {
                ghost?.clear()
                eraseOpenTerminalLine()
                return
            }
        }
        // "Tell the terminal to run the tests", "tell Claude to fix the
        // failing test": typed at the prompt in the background, Return not
        // pressed. Focus stays where it is.
        if let dictation = Self.terminalDictation(utterance, terminalActive: terminalDraftIsCurrent) {
            ghost?.clear()
            typeIntoTerminal(dictation)
            return
        }
        if Self.isEraseIt(utterance), messagesDraftOpenedAt.map({ Date().timeIntervalSince($0) < 10 * 60 }) ?? false {
            ghost?.clear()
            eraseOpenMessagesDraft()
            return
        }
        // "Undo that" reverts Peeky's last background write wherever it went
        // — not gated on a Messages thread, so an empty stack still gets a
        // spoken "nothing to undo" rather than being dictated somewhere.
        if Self.isUndoIt(utterance) {
            // A preview holding only the command's own words ("un undo that",
            // previewed before the phrase was recognisable) isn't something
            // Peeky started writing — clear it silently and undo for real.
            let previewIsCommand = ghost.map { Self.isUndoIt($0.written) } ?? false
            if let ghost, !ghost.written.isEmpty, !previewIsCommand {
                // The last thing Peeky put on screen is the live preview
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
        if Self.isNeverMind(utterance), gmailDraftOpenedAt != nil || messagesDraftOpenedAt != nil || terminalDraftOpenedAt != nil || chatSiteDraftOpenedAt != nil {
            ghost?.clear()
            gmailDraftOpenedAt = nil
            messagesDraftOpenedAt = nil
            messagesDraftText = nil
            terminalDraftOpenedAt = nil
            chatSiteDraftOpenedAt = nil
            let message = "OK — the draft stays as it is; I'm back to taking commands."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        // "Open AI Studio" / "go to ChatGPT": select the tab (or open the
        // site) and make it the dictation target — no planner, no guessing
        // at an app called "AI Studio" (seen live: the planner tried exactly
        // that and failed).
        if let site = ChatSiteActions.openRequest(utterance) {
            ghost?.clear()
            openChatSite(site)
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
        // While a compose Peeky opened is on screen, what the user says next
        // is the email — "tell them I'm interested in the sales role" — not a
        // command. Screen-aware dictation: Claude writes it in their voice.
        // Same for a Messages thread Peeky opened. Whichever was opened more
        // recently is the one being talked to.
        // …unless it's plainly a command — "actually, open David's
        // conversation" must not get typed to Dino Dad.
        let gateBypassed = Self.isAppCommand(utterance) || Self.isTerminalCommand(utterance)
        if gateBypassed { ghost?.clear() }
        // An AI chat site is the target — Peeky just opened it, or its tab is
        // in front (AI Studio, ChatGPT, Gemini…): the sentence is the prompt,
        // typed into its box word for word. Once Peeky opened it, it stays
        // the target even while the person looks at another window or their
        // phone (seen live: the frontmost app was Peeky's own transcript).
        if !gateBypassed {
            let opened = chatSiteDraftIsCurrent ? chatSiteTarget?.site : nil
            let inFront = BrowserTabReader.supportedBundleIDs.contains(targetApp?.bundleIdentifier ?? "")
                ? ChatSiteActions.frontSite() : nil
            if let site = opened ?? inFront {
                ghost?.clear()
                dictateIntoChatSite(utterance, site: site, apiKey: apiKey)
                return
            }
        }
        let gmailActive = !gateBypassed && (gmailDraftOpenedAt.map { Date().timeIntervalSince($0) < 10 * 60 } ?? false)
        // A thread Peeky opened, or one the user is simply looking at: with
        // Messages in front and a conversation showing, the next sentence is
        // the message. (Seen live: "open Messages" via the planner, then "I
        // will see you later today" — the planner typed it and proposed
        // pressing Return, so a send card appeared before "send it" was said.)
        let messagesInFront = [targetApp?.bundleIdentifier, NSWorkspace.shared.frontmostApplication?.bundleIdentifier]
            .contains(MessagesActions.bundleID)
        let messagesActive = !gateBypassed && ((messagesDraftOpenedAt.map { Date().timeIntervalSince($0) < 10 * 60 } ?? false)
                                               || messagesInFront)
        let messagesFirst = messagesInFront || (messagesDraftOpenedAt ?? .distantPast) > (gmailDraftOpenedAt ?? .distantPast)
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
        // The display Peeky's panel sits on is the one the user is working
        // on — they put it there. With two Safari windows on two screens,
        // this is what picks the right one to read.
        let screen = panel.screen ?? Self.screenShowing(targetApp) ?? workingScreen
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
                    return await self.confirmPlannerStep(question, screen: screen)
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
    /// What a confirm is for. `.send` gets a Cancel/Send card on the phone and
    /// a "Send" button on the Mac; everything else is the generic No/Yes.
    enum ConfirmKind {
        case action
        case send(recipient: String)
        /// A staged terminal line about to run in `where`.
        case run(where: String)
    }

    /// The phone protocol is one message per line, so a question that carries
    /// a quoted preview ("Send to X?\n\n<text>") has to travel with its
    /// newlines folded into U+2028; the phone unfolds them. Tabs separate
    /// fields, so they're flattened too.
    static func encodeConfirmField(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
            .replacingOccurrences(of: "\t", with: " ")
    }

    @MainActor
    private func requestConfirm(question: String, screen: NSScreen, kind: ConfirmKind = .action) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            log.notice("requesting confirm \(id, privacy: .public): \(question, privacy: .public)")
            pendingConfirms[id] = continuation
            let cursor = NSEvent.mouseLocation
            let title: String, label: String, icon: String, wire: String
            switch kind {
            case .action:
                title = "Confirm this action?"; label = "Do It"; icon = "checkmark.circle"
                wire = "CONFIRM \(id)\t\(Self.encodeConfirmField(question))"
            case .send(let recipient):
                title = "Send this message?"; label = "Send"; icon = "paperplane"
                wire = "CONFIRM \(id)\t\(Self.encodeConfirmField(question))\tSEND\t\(Self.encodeConfirmField(recipient))"
            case .run(let place):
                title = "Run this command?"; label = "Run"; icon = "terminal"
                wire = "CONFIRM \(id)\t\(Self.encodeConfirmField(question))\tRUN\t\(Self.encodeConfirmField(place))"
            }
            confirmPanel.show(
                title: title,
                message: question,
                confirmLabel: label,
                icon: icon,
                tint: .blue,
                near: cursor,
                on: screen
            ) { [weak self] confirmed in
                self?.resolveConfirm(id: id, result: confirmed)
            }
            remote.broadcast(wire)
            hud.decide(question.components(separatedBy: "\n\n").first ?? question, outcome: .pending)
        }
    }

    /// "Yes" / "send it" / "go ahead" while a confirm is up answers it; so does
    /// "no" / "cancel" / "never mind". Returns nil when the words aren't a
    /// plain answer — then they're treated as a new command as usual.
    static func spokenConfirmAnswer(_ utterance: String) -> Bool? {
        var words = utterance.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["ok", "okay", "hey", "peeky", "clicky", "please", "just", "um", "uh", "and", "so", "well"]
        while let first = words.first, leadIns.contains(first), words.count > 1 { words.removeFirst() }
        words = stripStutters(words)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "send", "sent", "ship",
                                "go", "ahead", "do", "it", "that", "this", "the", "message", "text", "email", "now",
                                "please", "ok", "okay", "fine", "correct", "right", "absolutely", "affirmative"]
        let no: Set<String> = ["no", "nope", "nah", "cancel", "stop", "don't", "dont", "never", "mind", "nevermind",
                               "wait", "hold", "on", "abort", "negative", "not", "yet", "it", "that", "this", "please",
                               "the", "send", "sending"]
        let hasNoVerb = words.contains { ["no", "nope", "nah", "cancel", "stop", "don't", "dont", "never",
                                          "nevermind", "wait", "hold", "abort", "negative", "not"].contains($0) }
        if hasNoVerb, words.allSatisfy({ no.contains($0) }) { return false }
        let hasYesVerb = words.contains { ["yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed", "send", "sent",
                                           "ship", "go", "do", "ok", "okay", "correct", "absolutely", "affirmative"].contains($0) }
        if hasYesVerb, words.allSatisfy({ yes.contains($0) }) { return true }
        return nil
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
        hud.report(result ? "Confirmed" : "Cancelled", ok: result)
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
        let screen = workingScreen
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

    /// Stops whatever Peeky is doing right now: cancels the in-flight
    /// request, silences speech, and returns the panel to Ready.
    private func stop() {
        let wasStreaming = talkStreaming
        abandonWork()
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
            if panel.state.tab == .code {
                panel.state.logCode(.status, "Stopped.")
            } else if panel.state.answer.isEmpty || panel.state.answer.hasSuffix("…") {
                panel.state.answer = "Stopped."
                panel.state.logTalk(.status, "Stopped.")
            }
        } else if panel.state.status == .answering {
            panel.state.status = .idle
        }
    }

    /// The cancelling half of `stop()`: drops the in-flight request and any
    /// Talk session without touching the listening state or telling the
    /// phone to stop — for when the phone itself is taking over (a new ASK).
    private func abandonWork() {
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
        if talkStreaming { talkRanWords = talkDispatched }
        streamPauseTask?.cancel()
        streamTranscript = ""
        talkStreaming = false
        takeGhostDraft()?.clear()
        talkSession = false
        phoneAskInFlight = false
        panel.state.chaining = false
        talkQueue = []
        talkDispatched = []
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
        let screen = workingScreen

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

    /// Matches "move this to the trash", "trash this file", "delete this",
    /// "delete these photos", etc.
    private static func isTrashIntent(_ question: String) -> Bool {
        let lowered = question.lowercased()
        let action = lowered.contains("trash") || lowered.contains("delete")
        let target = lowered.contains("this") || lowered.contains("these") || lowered.contains("file")
            || lowered.contains("it") || lowered.contains("doc") || lowered.contains("photo")
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
                let screen = workingScreen
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

    private func handlePhotosDeleteCommand() {
        busy = true
        panel.state.status = .thinking
        panel.state.answer = ""
        panel.state.errorText = nil

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            guard let count = PhotosActions.selectedCount() else {
                fail("Nothing selected in Photos — select one or more photos first.")
                return
            }
            guard id == requestID else { return }
            panel.state.status = .answering
            let (title, message): (String, String) = count == 1
                ? ("Delete Photo?", "This photo will move to Recently Deleted. You can restore it for 30 days.")
                : ("Delete \(count) Photos?", "These \(count) photos will move to Recently Deleted. You can restore them for 30 days.")
            panel.state.answer = "Confirm \(count == 1 ? "deleting this photo" : "deleting \(count) photos")."
            let cursor = NSEvent.mouseLocation
            let screen = workingScreen
            confirmPanel.show(
                title: title,
                message: message,
                confirmLabel: "Delete",
                near: cursor,
                on: screen
            ) { [weak self] confirmed in
                guard let self else { return }
                if confirmed {
                    PhotosActions.deleteSelection { message, ok in
                        if ok {
                            self.panel.state.status = .answering
                            let text = "Moved \(count) photo\(count == 1 ? "" : "s") to Recently Deleted."
                            self.panel.state.answer = text
                            self.speak(text)
                        } else {
                            self.fail(message)
                        }
                    }
                } else {
                    self.panel.state.status = .idle
                    self.panel.state.answer = "Cancelled — nothing was deleted."
                }
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
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "peeky", "clicky", "can", "could", "would", "you", "please",
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
    /// planner round trip. Only fires while a Gmail draft Peeky opened is
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
                                     "can", "could", "would", "you", "let's", "lets", "hey", "peeky", "clicky", "hit", "press"]
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
    /// "Un— undo that", "erase erase that": a repeated or half-said word in
    /// front of the verb is a stutter, not a lead-in — drop it so the fast
    /// paths still match (seen live: every "un undo that" fell to Claude).
    private static func stripStutters(_ words: [String]) -> [String] {
        var words = words
        while words.count >= 2, words[1].hasPrefix(words[0]) { words.removeFirst() }
        return words
    }

    private static func isEraseIt(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "peeky", "clicky", "no", "wait", "please", "just", "can", "you", "let's", "lets", "and", "now"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        words = stripStutters(words)
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
    /// — revert Peeky's last background write. Kept tight (a verb plus
    /// filler) so "undo the second sentence" stays a revision for the drafter.
    static func isUndoIt(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "peeky", "clicky", "no", "wait", "please", "just", "can", "you",
                                    "let's", "lets", "and", "now", "never", "mind", "nevermind", "oops", "uh", "um", "sorry"]
        while let first = words.first, leadIns.contains(first) { words.removeFirst() }
        words = stripStutters(words)
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

    /// Speech that is clearly an instruction to Peeky rather than words for
    /// the open draft: "actually, let's open up a conversation with David",
    /// "switch to Safari", "write an email to Sam". Checked after stripping
    /// lead-ins, so a message that merely *contains* "open" still counts as
    /// dictation ("tell him the store is open till nine").
    static func isAppCommand(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["actually", "ok", "okay", "hey", "peeky", "clicky", "let's", "lets", "can", "could", "you",
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
        let terminal = terminalDraftOpenedAt ?? .distantPast
        let recent = { (date: Date) in Date().timeIntervalSince(date) < 10 * 60 }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.chatSiteDraftIsCurrent {
                self.submitChatSitePrompt()
            } else if terminal > messages, terminal > gmail, recent(terminal) {
                await self.runOpenTerminalLine()
            } else if messages > gmail, recent(messages) {
                await self.sendOpenMessagesDraft()
            } else if recent(gmail) {
                await self.sendOpenGmailDraft()
            } else if MessagesActions.currentComposeText() != nil {
                // Nothing Peeky drafted itself is current, but there's text
                // sitting in an open Messages thread — typed by the planner
                // ("open Messages", then dictating straight in) or by hand.
                // Seen live: "looks good, send a text" after exactly that fell
                // through to Gmail and answered "No Gmail draft from me".
                await self.sendOpenMessagesDraft()
            } else if MessagesActions.openConversation() != nil {
                // Thread open, box empty: nothing to send here, and Gmail is
                // not what they meant.
                let message = "The message box in Messages is empty — tell me what to say first."
                self.panel.state.status = .answering
                self.panel.state.answer = message
                self.panel.state.logTalk(.status, message)
                self.remote.broadcast("STATUS \(message)")
            } else {
                await self.sendOpenGmailDraft()
            }
        }
    }

    /// The one moment that can't be taken back. The card names who and quotes
    /// what, on the phone and on the Mac; a spoken "yes" / "send" or "no" /
    /// "cancel" answers it too. Cancel leaves the draft exactly where it was.
    private func confirmSendOpenDraft(to recipient: String, via app: String, body: String) async -> Bool {
        let screen = workingScreen
        panel.state.status = .answering
        let ask = "Send this to \(recipient)?"
        panel.state.answer = ask
        panel.state.logTalk(.status, ask)
        guard await confirmSend(to: recipient, via: app, body: body, screen: screen) else {
            let message = "Not sent — the draft is still there."
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return false
        }
        return true
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
        hud.report(message, ok: outcome.ok)
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

    private func sendOpenMessagesDraft() async {
        // What's actually in the box wins over what we last wrote — the user
        // may have edited it by hand since, or the planner may have typed it
        // without going through the draft path at all.
        let typed = MessagesActions.currentComposeText()
        guard typed != nil || messagesDraftText != nil, let open = MessagesActions.openConversation() else {
            let message = "Nothing typed in Messages yet — tell me what to say first."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        let body = typed ?? messagesDraftText ?? ""
        guard await confirmSendOpenDraft(to: open, via: "Messages", body: body) else { return }
        panel.state.status = .thinking
        MessagesActions.sendTyped { [weak self] message, ok in
            guard let self else { return }
            // The thread is still open after a send, and the next sentence is
            // almost always a follow-up to it (observed live: "No I actually
            // got work on Friday" right after "send it" fell to the planner
            // and went nowhere). Keep drafting into it; only the text resets.
            if ok { self.messagesDraftOpenedAt = Date(); self.messagesDraftText = nil }
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
                                    "can", "could", "you", "let's", "lets", "hey", "peeky", "clicky", "go", "ahead", "alright"]
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
        let leadIns: Set<String> = ["hey", "peeky", "clicky", "ok", "okay", "so", "um", "uh", "can", "could", "would", "you",
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
        // there from before Peeky opened this thread included — so "erase
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
            // The landed-write confirmation lived only on the panel and the
            // phone's status line — easy to miss with the panel behind other
            // windows (observed live: "I didn't see it land").
            if ok { toast.show("Written — say “send it” or “undo that”", icon: "text.bubble.fill", tint: .green) }
        }
    }

    private func sendOpenGmailDraft() async {
        guard let opened = gmailDraftOpenedAt, Date().timeIntervalSince(opened) < 10 * 60 else {
            let message = "No Gmail draft from me to send — say “email that to someone” first."
            panel.state.status = .answering
            panel.state.answer = message
            panel.state.logTalk(.status, message)
            remote.broadcast("STATUS \(message)")
            return
        }
        let compose = GmailDrafter.openCompose(recipientHint: gmailDraftRecipient)
        let recipient = compose?.to.isEmpty == false ? compose!.to : (gmailDraftRecipient ?? "this recipient")
        guard await confirmSendOpenDraft(to: recipient, via: "Gmail", body: compose?.body ?? "") else { return }
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

    // MARK: - Terminal as a write target

    /// The terminal line is the draft "send it" / "erase that" act on when
    /// it's the most recent thing Peeky opened and it's still fresh.
    private var terminalDraftIsCurrent: Bool {
        guard let opened = terminalDraftOpenedAt, Date().timeIntervalSince(opened) < 10 * 60 else { return false }
        return opened > (messagesDraftOpenedAt ?? .distantPast) && opened > (gmailDraftOpenedAt ?? .distantPast)
    }

    struct TerminalDictation: Equatable {
        /// What to type, as said (commands get spoken symbols normalised).
        let text: String
        /// Add to the line already typed rather than starting a new one.
        let append: Bool
        /// Addressed to the agent at the prompt (Claude Code, Copilot CLI…)
        /// — natural language, left exactly as spoken.
        let agent: Bool
        /// Which agent, when one was named ("Claude Code"); nil for "the agent".
        var agentName: String? = nil
        /// "…on the other screen" / "…on screen 2" / "…on the left screen".
        var screen: ScreenHint? = nil
    }

    enum ScreenHint: Equatable {
        case other
        case index(Int)
        case left, right
    }

    /// Pulls a screen hint out of the sentence and returns what's left.
    static func extractScreenHint(_ text: String) -> (String, ScreenHint?) {
        let numbers = ["one": 1, "1": 1, "two": 2, "2": 2, "three": 3, "3": 3, "first": 1, "second": 2, "third": 3]
        let patterns = [
            "\\s*(?:on|in|at|to)\\s+(?:the\\s+)?(other|left|right|first|second|third)\\s+(?:screen|monitor|display)\\b",
            "\\s*(?:on|in|at|to)\\s+(?:screen|monitor|display)\\s+(one|two|three|1|2|3)\\b",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text), let word = Range(match.range(at: 1), in: text) else { continue }
            let key = text[word].lowercased()
            let hint: ScreenHint
            switch key {
            case "other": hint = .other
            case "left": hint = .left
            case "right": hint = .right
            default:
                guard let n = numbers[key] else { continue }
                hint = .index(n)
            }
            var rest = text
            rest.removeSubrange(whole)
            return (rest.trimmingCharacters(in: .whitespacesAndNewlines), hint)
        }
        return (text, nil)
    }

    private static let terminalNouns = "(?:terminal|shell|console|command line|prompt)"
    private static let agentNouns = "(?:claude(?:\\s+code)?|cloud(?:\\s+code)?|co-?\\s?pilot|codex|cursor|gemini|aider|the agent|the ai|the assistant|the bot|the coding agent)"

    /// "Tell the terminal to run the tests" → "run the tests" typed at the
    /// prompt. Only explicit addressing counts; nothing is typed into a
    /// terminal because it happens to be open.
    static func terminalDictation(_ utterance: String, terminalActive: Bool) -> TerminalDictation? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = ["actually", "ok", "okay", "hey", "peeky", "clicky", "please", "now", "um", "uh", "so", "and then", "then",
                       "can you", "could you", "would you", "let's", "lets", "just", "go ahead and"]
        var stripped = true
        while stripped {
            stripped = false
            for lead in leadIns {
                if let range = text.range(of: "^\(NSRegularExpression.escapedPattern(for: lead))[,\\s]+",
                                          options: [.regularExpression, .caseInsensitive]) {
                    text.removeSubrange(range)
                    stripped = true
                }
            }
        }
        let (rest, screenHint) = extractScreenHint(text)
        text = rest
        let T = terminalNouns, A = agentNouns
        let shellPatterns = [
            "^(?:tell|ask)\\s+(?:the\\s+)?\(T)\\s+(?:to\\s+)?(.+)$",
            "^(?:in|into|on|at)\\s+(?:the\\s+)?\(T)[,:]?\\s+(?:type|run|write|say|enter|put)?\\s*(.+)$",
            "^(?:type|enter|write|put|run|execute)\\s+(?:this\\s+|that\\s+)?(?:in|into|on|at)\\s+(?:the\\s+)?\(T)[,:]?\\s+(.+)$",
            "^(?:type|enter|write|put|run|execute)\\s+(.+?)\\s+(?:in|into|on|at)\\s+(?:the\\s+)?\(T)$",
            "^\(T)[,:]\\s+(.+)$",
        ]
        // Only real agent names can be addressed directly ("Claude, what does
        // this do?") — "the agent" needs a verb, or every sentence starting
        // with "the" would be a candidate.
        let named = "(?:claude(?:\\s+code)?|cloud(?:\\s+code)?|co-?\\s?pilot|codex|cursor|gemini|aider)"
        let agentPatterns = [
            "^(?:tell|ask)\\s+(\(A))\\s+(?:to\\s+)?(.+)$",
            "^(?:say|send)\\s+(?:this\\s+)?to\\s+(\(A))[,:]?\\s+(.+)$",
            "^(?:hey\\s+|ok\\s+|okay\\s+)?(\(named))[,:]?\\s+(.{4,})$",
        ]
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let captured = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            return captured.isEmpty ? nil : captured
        }
        for pattern in agentPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let who = Range(match.range(at: 1), in: text), let what = Range(match.range(at: 2), in: text) else { continue }
            let captured = text[what].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !captured.isEmpty else { continue }
            return TerminalDictation(text: captured, append: false, agent: true,
                                     agentName: TerminalActions.agentName(spoken: String(text[who])), screen: screenHint)
        }
        for pattern in shellPatterns {
            if let captured = capture(pattern) {
                return TerminalDictation(text: spokenSymbols(captured), append: false, agent: false, screen: screenHint)
            }
        }
        // A line is already at the prompt: "type --verbose" / "add dash v"
        // extends it. Anything else said isn't for the terminal.
        if terminalActive, let captured = capture("^(?:type|add|append|also)\\s+(.+)$") {
            return TerminalDictation(text: " " + spokenSymbols(captured), append: true, agent: false)
        }
        return nil
    }

    /// Speech gives "npm test dash dash watch"; the shell wants
    /// "npm test --watch". Only the handful of tokens people actually say.
    static func spokenSymbols(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            ("\\b(?:dash dash|double dash|hyphen hyphen)\\s+", "--"),
            ("\\b(?:dash|hyphen|minus)\\s+(?=\\S)", "-"),
            ("\\bdot\\s+slash\\s+", "./"),
            ("\\s+dot\\s+", "."),
            ("\\s+(?:slash|forward slash)\\s+", "/"),
            ("\\s+underscore\\s+", "_"),
            ("\\b(?:tilde|tilda)\\s*", "~"),
            ("\\s+(?:pipe|pipe to)\\s+", " | "),
            ("\\s+ampersand ampersand\\s+", " && "),
        ]
        for (pattern, replacement) in rules {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        // "dot" as a word at the end ("run dot slash build dot sh") — the
        // space-bounded rule misses edges.
        out = out.replacingOccurrences(of: "\\s+dot\\b", with: ".", options: [.regularExpression, .caseInsensitive])
        return out
    }

    /// "Run it", "hit enter", "execute", "go" — press Return on the typed line.
    static func isRunIt(_ utterance: String) -> Bool {
        var words = stripStutters(utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let leadIns: Set<String> = ["ok", "okay", "hey", "peeky", "clicky", "please", "now", "and", "then", "just", "go", "ahead", "yes", "yeah"]
        while words.count > 1, let first = words.first, leadIns.contains(first) { words.removeFirst() }
        guard !words.isEmpty, words.count <= 4 else { return false }
        let verbs: Set<String> = ["run", "execute", "enter", "return", "go", "fire", "submit"]
        let fillers: Set<String> = ["it", "that", "this", "the", "command", "line", "now", "please", "key", "press", "hit",
                                    "enter", "return", "button", "off", "ahead"]
        guard words.contains(where: verbs.contains) else { return false }
        return words.allSatisfy { verbs.contains($0) || fillers.contains($0) }
    }

    static func isTerminalCommand(_ utterance: String) -> Bool {
        terminalDictation(utterance, terminalActive: false) != nil
    }

    private func typeIntoTerminal(_ dictation: TerminalDictation) {
        let text = dictation.text, append = dictation.append, agent = dictation.agent
        // The display you're working on: where Peeky's panel is, else the
        // frontmost app's window, else the cursor.
        let working = panel.screen ?? Self.screenShowing(NSWorkspace.shared.frontmostApplication) ?? activeScreen
        var request = TerminalActions.Request(agent: dictation.agentName, anyAgent: agent && dictation.agentName == nil)
        let byX = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        switch dictation.screen {
        case .other: request.otherScreenThan = working
        case .index(let n): request.screenIndex = n
        case .left: request.screenIndex = byX.first.flatMap { NSScreen.screens.firstIndex(of: $0) }.map { $0 + 1 }
        case .right: request.screenIndex = byX.last.flatMap { NSScreen.screens.firstIndex(of: $0) }.map { $0 + 1 }
        case nil: break
        }
        let session: TerminalActions.Session
        if append, let existing = terminalTarget, existing.isValid, dictation.screen == nil, dictation.agentName == nil {
            session = existing.session
        } else {
            switch TerminalActions.choose(request, workingScreen: working) {
            case .one(let chosen): session = chosen
            case .noTerminal:
                finishTerminal("No terminal is open — open Terminal or iTerm first, then say that again.", ok: false)
                return
            case .noAgent(let name):
                finishTerminal("I don't see \(name) running in any terminal tab.", ok: false)
                return
            case .none:
                finishTerminal("No terminal window on that screen.", ok: false)
                return
            case .noScreen(let n):
                let count = NSScreen.screens.count
                finishTerminal("There's no screen \(n) — you have \(count) \(count == 1 ? "display" : "displays").", ok: false)
                return
            }
        }
        synthesizer.stopSpeaking(at: .immediate)
        let target: TerminalLineTarget
        let previous: String
        if append, let existing = terminalTarget, existing.isValid, existing.session.windowID == session.windowID,
           existing.session.tabIndex == session.tabIndex {
            target = existing
            previous = existing.typed
        } else {
            target = TerminalLineTarget(session: session, typed: "")
            previous = ""
        }
        let newValue = previous + text
        guard TerminalActions.stage(text, in: session) else {
            finishTerminal("Couldn't reach \(session.name) — check MyClicky has Automation access to it in Privacy & Security.", ok: false)
            return
        }
        target.setTyped(newValue)
        terminalTarget = target
        terminalDraftOpenedAt = Date()
        WriteUndoStack.shared.forget(key: target.undoKey)
        WriteUndoStack.shared.record(target: target, previousValue: previous, newValue: newValue, label: session.label)
        if let frame = session.frame { ring.show(over: frame, duration: 1.8) }
        let shown = newValue.count > 80 ? String(newValue.prefix(80)) + "…" : newValue
        let verb = session.kind.stagesAtPrompt ? "Typed" : "Ready for"
        let message = session.agent != nil ? "\(verb) \(session.label): “\(shown)” — say “send it” to let it go, or “erase that”."
                                           : "\(verb) \(session.label): “\(shown)” — say “run it”, or “erase that”."
        ActivityLog.recordAction("terminal-draft", ["app": session.label, "agent": agent ? "yes" : "no",
                                                    "append": append ? "yes" : "no", "chars": String(newValue.count),
                                                    "screen": dictation.screen.map { String(describing: $0) } ?? "auto"])
        finishTerminal(message, ok: true)
        toast.show("\(session.label): \(shown)", icon: "terminal.fill", tint: .cyan)
    }

    private func runOpenTerminalLine() async {
        guard let target = terminalTarget, target.isValid, !target.typed.isEmpty else {
            finishTerminal("Nothing staged for the terminal yet — say “tell the terminal …” first.", ok: false)
            return
        }
        let screen = workingScreen
        panel.state.status = .answering
        let line = target.typed
        let preview = line.count > 220 ? String(line.prefix(220)) + "…" : line
        let confirmed: Bool
        if let agent = target.session.agent {
            panel.state.answer = "Send this to \(agent)?"
            confirmed = await requestConfirm(question: "Send to \(target.session.label)?\n\n\(preview)", screen: screen,
                                             kind: .send(recipient: agent))
        } else {
            panel.state.answer = "Run this in \(target.session.name)?"
            confirmed = await requestConfirm(question: "Run in \(target.session.name)?\n\n\(preview)", screen: screen,
                                             kind: .run(where: target.session.name))
        }
        ActivityLog.recordAction("terminal-run-confirm", ["via": target.session.label, "ok": confirmed ? "yes" : "no"])
        guard confirmed else {
            finishTerminal("Not run — the line is still staged; say “run it” when ready, or “erase that”.", ok: true, hudOK: false)
            return
        }
        let seen = TerminalActions.run(line, in: target.session)
        WriteUndoStack.shared.forget(key: target.undoKey)
        target.consume()
        terminalDraftOpenedAt = Date() // still talking to this terminal
        if let frame = target.session.frame { ring.show(over: frame, duration: 1.5) }
        let message = seen == false ? "Sent it to \(target.session.label) but couldn't see it in the tab — check there."
                                    : (target.session.agent != nil ? "Sent to \(target.session.label)." : "Running in \(target.session.name).")
        finishTerminal(message, ok: seen != false)
        toast.show(message, icon: seen == false ? "exclamationmark.triangle.fill" : "terminal.fill",
                   tint: seen == false ? .orange : .green)
    }

    private func eraseOpenTerminalLine() {
        guard let target = terminalTarget, target.isValid, !target.typed.isEmpty else {
            finishTerminal("Nothing of mine staged for the terminal to erase.", ok: false)
            return
        }
        let result = target.restore("")
        WriteUndoStack.shared.forget(key: target.undoKey)
        let message = result.landed ? "Erased the line for \(target.session.name)."
                                    : "Couldn't take the line back in \(target.session.name) — check the prompt."
        ActivityLog.recordAction("terminal-erase-line", ["app": target.session.name, "result": String(describing: result)])
        finishTerminal(message, ok: result.landed)
    }

    private func finishTerminal(_ message: String, ok: Bool, hudOK: Bool? = nil) {
        hud.report(message, ok: hudOK ?? ok)
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(ok ? .status : .error, message)
        remote.broadcast("STATUS \(message)")
        if !panel.state.textOnlyMode { speak(message) }
    }

    // MARK: - AI chat sites as a write target

    /// The chat-site prompt is the draft "send it" / "erase that" act on when
    /// it's the freshest thing Peeky wrote and its tab is still in front.
    private var chatSiteDraftIsCurrent: Bool {
        guard let opened = chatSiteDraftOpenedAt, Date().timeIntervalSince(opened) < 10 * 60,
              let target = chatSiteTarget, target.isValid else { return false }
        return opened > (messagesDraftOpenedAt ?? .distantPast) && opened > (gmailDraftOpenedAt ?? .distantPast)
            && opened > (terminalDraftOpenedAt ?? .distantPast)
    }

    /// "Actually…", "change that to…", "make it shorter", "I meant…": said
    /// while Peeky's own text sits in the box, this is about the prompt, not
    /// more of it. Anything else appends verbatim — a long question spoken
    /// with pauses arrives as several segments and must simply keep going.
    static func isPromptRevision(_ utterance: String) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
        let leadIns: Set<String> = ["ok", "okay", "hey", "peeky", "clicky", "um", "uh", "oh", "no", "wait", "hmm", "so", "and", "please", "can", "could", "you"]
        while words.count > 1, let first = words.first, leadIns.contains(first) { words.removeFirst() }
        words = stripStutters(words)
        let joined = words.joined(separator: " ")
        let starts = ["actually", "change that", "change it", "change the", "instead of", "instead say", "scratch that", "scrap that",
                      "replace", "make it", "make that", "make the", "rewrite", "reword", "rephrase", "shorter", "longer",
                      "correction", "i meant", "i mean", "swap", "fix that", "fix the", "take out", "take that out", "remove the",
                      "delete the", "drop the", "get rid of the", "add that", "also ask", "also mention", "also say", "also add",
                      "it's not", "that's not", "that should", "it should", "should say", "should be"]
        return starts.contains { joined.hasPrefix($0) }
    }

    /// Speech arrives lowercase and unpunctuated; the start of a prompt gets
    /// a capital, and a sentence appended after a pause gets a full stop on
    /// the one before it if it has none.
    static func tidyPromptSegment(_ text: String, appendingTo existing: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let capped = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return capped }
        let terminal = CharacterSet(charactersIn: ".!?:;,—-")
        let joiner = base.unicodeScalars.last.map { terminal.contains($0) } ?? true ? " " : ". "
        return base + joiner + capped
    }

    private func openChatSite(_ site: ChatSiteActions.Site) {
        synthesizer.stopSpeaking(at: .immediate)
        ring.hide()
        let existed = ChatSiteActions.open(site)
        let target = (chatSiteTarget?.site == site ? chatSiteTarget : nil) ?? ChatSiteTarget(site: site)
        target.typed = ""
        chatSiteTarget = target
        chatSiteDraftOpenedAt = Date()
        chatSiteOpenedFreshAt = existed ? nil : Date()
        ActivityLog.recordAction("chatsite-open", ["site": site.name, "existed": existed ? "yes" : "no"])
        let message = "\(site.name) is up — tell me what to ask, then say “send it”."
        finishChatSite(message, ok: true, speak: false)
        toast.show(message, icon: "bubble.left.and.text.bubble.right.fill", tint: .cyan)
    }

    /// The box, waiting briefly for a page Peeky just opened to finish loading.
    private func readChatSiteBox(_ site: ChatSiteActions.Site) -> String? {
        var attempts = 1
        if let fresh = chatSiteOpenedFreshAt, Date().timeIntervalSince(fresh) < 20 { attempts = 8 }
        for attempt in 0..<attempts {
            if let text = ChatSiteActions.read(site) {
                chatSiteOpenedFreshAt = nil
                return text
            }
            if attempt < attempts - 1 { usleep(500_000) }
        }
        return nil
    }

    private func dictateIntoChatSite(_ utterance: String, site: ChatSiteActions.Site, apiKey: String) {
        synthesizer.stopSpeaking(at: .immediate)
        guard let existing = readChatSiteBox(site) else {
            finishChatSite("I can't reach the prompt box in \(site.name) — check the browser allows JavaScript from Apple Events.", ok: false, speak: true)
            return
        }
        let target = (chatSiteTarget?.site == site ? chatSiteTarget : nil) ?? ChatSiteTarget(site: site)
        let stillMine = !target.typed.isEmpty
            && existing.trimmingCharacters(in: .whitespacesAndNewlines) == target.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if stillMine, Self.isPromptRevision(utterance) {
            reviseChatSitePrompt(utterance, current: existing, target: target, apiKey: apiKey)
            return
        }
        let newValue = Self.tidyPromptSegment(utterance, appendingTo: existing)
        guard ChatSiteActions.write(newValue, into: site) else {
            finishChatSite("Couldn't type into \(site.name) — is the prompt box on screen?", ok: false, speak: true)
            return
        }
        target.typed = newValue
        chatSiteTarget = target
        chatSiteDraftOpenedAt = Date()
        WriteUndoStack.shared.record(target: target, previousValue: existing, newValue: newValue, label: site.name)
        if let frame = ChatSiteActions.inputFrame(site) { ring.show(over: frame, duration: 1.5) }
        let shown = newValue.count > 80 ? "…" + String(newValue.suffix(80)) : newValue
        let message = existing.isEmpty
            ? "Typed into \(site.name): “\(shown)” — keep talking to add more, say “send it”, or “erase that”."
            : "Added to your \(site.name) prompt: “\(shown)” — say “send it” when ready."
        ActivityLog.recordAction("chatsite-dictate", ["site": site.name, "append": existing.isEmpty ? "no" : "yes",
                                                      "chars": String(newValue.count)])
        // Not spoken: the mic is open and Peeky's own voice would be dictated
        // straight back into the box.
        finishChatSite(message, ok: true, speak: false)
        toast.show("\(site.name): \(shown)", icon: "text.cursor", tint: .cyan)
    }

    private func reviseChatSitePrompt(_ instruction: String, current: String, target: ChatSiteTarget, apiKey: String) {
        let site = target.site
        busy = true
        ring.hide()
        panel.state.status = .thinking
        panel.state.answer = "Changing it…"
        panel.state.errorText = nil
        remote.broadcast("STATUS_QUIET \(panel.state.answer)")
        ActivityLog.recordAction("chatsite-revise", ["site": site.name])

        requestID += 1
        let id = requestID
        currentTask = Task {
            defer { if id == requestID { busy = false; currentTask = nil } }
            let claude = AnthropicService(apiKey: apiKey)
            do {
                let revised = try await ChatSiteDrafter.revise(draft: current, instruction: instruction, claude: claude)
                guard id == requestID else { return }
                guard ChatSiteActions.write(revised, into: site) else {
                    finishChatSite("Rewrote it, but couldn't type into \(site.name) — is the tab still in front?", ok: false, speak: true)
                    return
                }
                target.typed = revised
                chatSiteTarget = target
                chatSiteDraftOpenedAt = Date()
                WriteUndoStack.shared.record(target: target, previousValue: current, newValue: revised, label: site.name)
                if let frame = ChatSiteActions.inputFrame(site) { ring.show(over: frame, duration: 1.5) }
                let shown = revised.count > 80 ? "…" + String(revised.suffix(80)) : revised
                finishChatSite("Changed: “\(shown)” — say “send it”, or “undo that”.", ok: true, speak: false)
                toast.show("\(site.name): \(shown)", icon: "pencil.line", tint: .cyan)
            } catch {
                guard id == requestID else { return }
                finishChatSite("Couldn't change that: \(error.localizedDescription)", ok: false, speak: true)
            }
        }
    }

    private func submitChatSitePrompt() {
        guard let target = chatSiteTarget, target.isValid else {
            finishChatSite("The chat tab isn't in front any more.", ok: false, speak: true)
            return
        }
        let site = target.site
        let current = ChatSiteActions.read(site) ?? target.typed
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishChatSite("The prompt box in \(site.name) is empty — tell me what to ask first.", ok: false, speak: true)
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        guard let how = ChatSiteActions.submit(site) else {
            finishChatSite("Couldn't press Send in \(site.name) — hit Enter there.", ok: false, speak: true)
            return
        }
        WriteUndoStack.shared.forget(key: target.undoKey)
        target.typed = ""
        chatSiteDraftOpenedAt = Date() // still talking to this site
        ActivityLog.recordAction("chatsite-submit", ["site": site.name, "via": how, "chars": String(current.count)])
        let message = "Sent to \(site.name)."
        finishChatSite(message, ok: true, speak: false)
        toast.show(message, icon: "paperplane.fill", tint: .green)
    }

    private func eraseChatSitePrompt() {
        guard let target = chatSiteTarget, target.isValid else {
            finishChatSite("The chat tab isn't in front any more.", ok: false, speak: true)
            return
        }
        let site = target.site
        let existing = ChatSiteActions.read(site) ?? target.typed
        guard ChatSiteActions.write("", into: site) else {
            finishChatSite("Couldn't clear the prompt box in \(site.name).", ok: false, speak: true)
            return
        }
        target.typed = ""
        chatSiteDraftOpenedAt = Date()
        if !existing.isEmpty {
            WriteUndoStack.shared.record(target: target, previousValue: existing, newValue: "", label: site.name)
        }
        ActivityLog.recordAction("chatsite-erase", ["site": site.name])
        finishChatSite(existing.isEmpty ? "Already empty — tell me what to ask." : "Cleared the \(site.name) prompt — tell me what to ask instead.",
                       ok: true, speak: false)
    }

    /// `speak` covers both the Mac's voice and the phone's: while dictating,
    /// the mic is open, so a status is shown on the phone but not read out.
    private func finishChatSite(_ message: String, ok: Bool, speak: Bool) {
        hud.report(message, ok: ok)
        panel.state.status = .answering
        panel.state.answer = message
        panel.state.logTalk(ok ? .status : .error, message)
        remote.broadcast("\(speak ? "STATUS" : "STATUS_QUIET") \(message)")
        if speak, !panel.state.textOnlyMode { self.speak(message) }
    }

    /// The planner gates its own irreversible steps with a free-text note
    /// ("Sending message…"). When that step is a send and a compose is open,
    /// the phone gets the same who-and-what card as every other send, not a
    /// bare yes/no.
    private func confirmPlannerStep(_ question: String, screen: NSScreen) async -> Bool {
        let lowered = question.lowercased()
        let sendShaped = lowered.contains("send") || lowered.contains("sending") || lowered.contains("reply")
        guard sendShaped else { return await requestConfirm(question: question, screen: screen) }
        if let recipient = MessagesActions.openConversation() {
            let body = MessagesActions.currentComposeText() ?? messagesDraftText ?? ""
            return await confirmSend(to: recipient, via: "Messages", body: body, screen: screen)
        }
        if let compose = GmailDrafter.openCompose(recipientHint: gmailDraftRecipient) {
            let recipient = compose.to.isEmpty ? (gmailDraftRecipient ?? "this recipient") : compose.to
            return await confirmSend(to: recipient, via: "Gmail", body: compose.body, screen: screen)
        }
        return await requestConfirm(question: question, screen: screen)
    }

    /// The preview. Shows who it resolved to and the opening of what's about
    /// to be sent, so "that" is never ambiguous at the moment it matters.
    private func confirmSend(to recipient: String, via app: String,
                             body: String, screen: NSScreen) async -> Bool {
        let preview = body.count > 220 ? String(body.prefix(220)) + "…" : body
        let confirmed = await requestConfirm(
            question: "Send to \(recipient) in \(app)?\n\n\(preview)",
            screen: screen,
            kind: .send(recipient: recipient)
        )
        ActivityLog.recordAction("send-confirm", ["via": app, "ok": confirmed ? "yes" : "no"])
        return confirmed
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
/// panel can show a Stop button while Peeky is talking.
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
