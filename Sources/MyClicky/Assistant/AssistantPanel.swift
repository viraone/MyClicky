import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AssistantStatus {
    case idle, listening, thinking, answering
}

/// What the panel is showing the user right now, one step finer than
/// `AssistantStatus`: listening splits into *speaking* and *paused*, because
/// the pause is where the user decides what happens next ("open Dino Dad's
/// conversation", or press STOP) and needs to be told they can.
enum AssistantPhase: Equatable {
    case ready, recording, paused, working, done

    /// Terminal palette — the same hues a shell prompt uses for its segments.
    var color: Color {
        switch self {
        case .ready: Color(red: 0.35, green: 0.78, blue: 0.98)     // cyan
        case .recording: Color(red: 1.0, green: 0.30, blue: 0.30)  // red
        case .paused: Color(red: 1.0, green: 0.68, blue: 0.20)     // amber
        case .working: Color(red: 0.72, green: 0.50, blue: 0.98)   // purple
        case .done: Color(red: 0.35, green: 0.85, blue: 0.45)      // green
        }
    }

    var label: String {
        switch self {
        case .ready: "ready"
        case .recording: "RECORDING"
        case .paused: "PAUSED"
        case .working: "working…"
        case .done: "DONE"
        }
    }

    var hint: String {
        switch self {
        case .ready: "press TALK, or click the mic"
        case .recording: "listening — keep talking"
        case .paused: "say a command (“open Dino Dad’s conversation”), or press STOP"
        case .working: "Peeky is on it"
        case .done: "finished — press TALK for the next one"
        }
    }

    var icon: String {
        switch self {
        case .ready: "chevron.right"
        case .recording: "record.circle.fill"
        case .paused: "pause.fill"
        case .working: "gearshape.2.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// The three card shapes. `half` is a narrow column — half the tall card's
/// width at its full height — for parking Peeky down one side of the
/// screen next to what's being worked on. Tabs go icon-only to fit.
enum PanelSize: Int, CaseIterable, Comparable {
    case half, normal, tall
    static func < (a: PanelSize, b: PanelSize) -> Bool { a.rawValue < b.rawValue }
    var symbol: String {
        switch self {
        case .half: return "rectangle.lefthalf.inset.filled"
        case .normal: return "rectangle.inset.filled"
        case .tall: return "rectangle.portrait.inset.filled"
        }
    }
    var label: String {
        switch self {
        case .half: return "Half width — a tall column down one side"
        case .normal: return "Normal"
        case .tall: return "Tall — room for a long answer"
        }
    }
}

enum AssistantTab: String, CaseIterable {
    /// Listed first so it's the leftmost tab: asking is what the panel is
    /// for most of the time.
    case ask = "Ask / Question"
    /// Region captures and dictation share one tab; both land on the clipboard together.
    case captureDictate = "Capture + Dictate"
    /// Voice/typed commands Peeky *acts on* (e.g. "create a calendar event
    /// at 2pm"), same plan-and-do flow as the phone's TALK button.
    case talk = "Talk / Request"
    /// A dropped project folder Claude can answer questions about. The
    /// project text is prompt-cached, so follow-ups cost a fraction of the
    /// first question.
    case code = "Peeky Code"

    var icon: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .captureDictate: "camera.on.rectangle"
        case .talk: "bolt.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// One-word name for the half-width column's tab bar.
    var shortName: String {
        switch self {
        case .ask: "Ask"
        case .captureDictate: "Capture"
        case .talk: "Talk"
        case .code: "Code"
        }
    }
}

/// One line of the Peeky Code tab's conversation.
struct CodeLogEntry: Identifiable, Equatable {
    enum Kind { case question, answer, status, error }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

/// One line of the Talk tab's terminal-style log.
struct TalkLogEntry: Identifiable, Equatable {
    /// `copied` carries the passage a copy verb put on the clipboard.
    enum Kind { case command, status, error, copied }
    let id = UUID()
    let time = Date()
    let kind: Kind
    let text: String
}

/// Which corner (or edge) of the panel is being dragged to resize it.
enum PanelResizeCorner: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    /// The whole bottom edge: drag it up to shrink the panel, down to grow
    /// it. Only the height changes; the top edge stays put.
    case bottom

    var isEdge: Bool { self == .bottom }

    /// The opposite corner, which stays put while this one moves.
    func anchor(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.maxX, y: rect.minY)
        case .topTrailing: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeading: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomTrailing, .bottom: NSPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// This corner's own point.
    func point(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.minX, y: rect.maxY)
        case .topTrailing: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeading: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomTrailing, .bottom: NSPoint(x: rect.maxX, y: rect.minY)
        }
    }
}

/// Which version of a screen capture — as originally grabbed, or after the
/// user edited it in an external app like Preview — rides on the clipboard.
enum CaptureClipboardChoice { case original, edited }

@MainActor
final class AssistantState: ObservableObject {
    @Published var status: AssistantStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            // A fresh recording starts hot; anything else clears the pause
            // machinery so a stale timer can't flip a later state.
            speechIdleTask?.cancel()
            speechActive = status == .listening
            updateMicLive()
        }
    }
    @Published var transcript = "" {
        didSet {
            // Words arriving means the user is speaking. Neither the phone nor
            // the Mac recogniser reports a pause, so it's inferred: partials
            // stop coming, the panel turns amber a moment later.
            if status == .listening, transcript != oldValue { noteSpeech() }
        }
    }
    /// True while partial transcripts are still arriving. Drives the
    /// recording/paused split that the user relies on to time a command.
    @Published private(set) var speechActive = false
    private var speechIdleTask: Task<Void, Never>?
    /// How long without new words before "speaking" becomes "paused". iOS
    /// finalises a segment after roughly this much silence, so it also lines
    /// up with when a spoken command would actually be committed.
    private static let pauseAfter: UInt64 = 1_400_000_000

    private func noteSpeech() {
        speechActive = true
        speechIdleTask?.cancel()
        speechIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pauseAfter)
            guard !Task.isCancelled, let self, self.status == .listening else { return }
            self.speechActive = false
            self.onPause?()
        }
    }

    /// Fires when speech has stopped for `pauseAfter` while listening — the
    /// Talk tab runs whatever was said since the last pause.
    var onPause: (() -> Void)?
    /// A Talk recording is still open after a command ran: the panel stays
    /// green until the next words arrive.
    @Published var chaining = false
    /// A phone-driven recording is open (TALK or ASK stream), whatever the
    /// panel's own status is showing. Mirrors the controller's flag.
    @Published var streaming = false {
        didSet { if streaming != oldValue { updateMicLive() } }
    }
    /// The mic is hot — locally or on the phone — and words are being
    /// captured right now. This is what the red REC badge follows; it is
    /// deliberately independent of `phase`, because a green "Done" with the
    /// stream still open is exactly the moment it must not go quiet.
    var micLive: Bool { status == .listening || streaming }
    /// When the current hot-mic stretch began, for the elapsed readout.
    @Published var micLiveSince: Date?
    private func updateMicLive() {
        if micLive {
            if micLiveSince == nil { micLiveSince = Date() }
        } else {
            micLiveSince = nil
        }
    }
    /// Talk tab log: every command spoken and every line Peeky reported
    /// back, timestamped. ⌘K clears it like a terminal.
    @Published var talkLog: [TalkLogEntry] = []

    func logTalk(_ kind: TalkLogEntry.Kind, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The planner re-posts the same status while it works; one line each.
        if let last = talkLog.last, last.kind == kind, last.text == trimmed { return }
        talkLog.append(TalkLogEntry(kind: kind, text: trimmed))
        if talkLog.count > 400 { talkLog.removeFirst(talkLog.count - 400) }
    }

    func clearTalkLog() {
        talkLog = []
        answer = ""
        errorText = nil
        copiedPreview = nil
    }

    // MARK: Peeky Code

    /// The project dropped on the Code tab, nil until one is.
    @Published var codeProject: CodeProject?
    /// True while a dropped folder is being read off disk.
    @Published var codeLoading = false
    /// Questions and answers about the project, oldest first.
    @Published var codeLog: [CodeLogEntry] = []
    /// What the last question cost — shown so the cache saving is visible.
    @Published var codeUsage: AnthropicService.Usage?
    /// The project card is expanded into its file list.
    @Published var codeShowingFiles = false
    /// Path of the file open in the preview, nil for the whole project.
    @Published var codeFocusedFile: String? {
        didSet { if codeFocusedFile != nil { codeShowingFiles = false } }
    }
    /// The file preview is folded down to its header row.
    @Published var codeViewerCollapsed = false
    /// Pictures (screenshots, mockups, error dialogs) that ride along with
    /// every code question until removed. Listed by name only.
    @Published var codeImages: [AskAttachment] = []
    static let maxCodeImages = 5
    /// Estimated dollars spent on code questions since install, from the
    /// token counts each answer reports. Persisted so it survives relaunch.
    @Published var codeSpentUSD: Double = UserDefaults.standard.double(forKey: codeSpentKey) {
        didSet { UserDefaults.standard.set(codeSpentUSD, forKey: Self.codeSpentKey) }
    }
    static let codeSpentKey = "peeky.code.spentUSD"
    /// Real month-to-date spend from the Admin API, nil without an admin key
    /// or before the first fetch. When present it replaces the estimate.
    @Published var codeLiveCost: AnthropicService.LiveCost?

    func logCode(_ kind: CodeLogEntry.Kind, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        codeLog.append(CodeLogEntry(kind: kind, text: trimmed))
    }

    /// The Q&A pairs sent back with the next question so it can build on
    /// them. Status and error lines aren't part of the conversation.
    var codeHistory: [(question: String, answer: String)] {
        var pairs: [(String, String)] = []
        var pendingQuestion: String?
        for entry in codeLog {
            switch entry.kind {
            case .question: pendingQuestion = entry.text
            case .answer:
                if let q = pendingQuestion { pairs.append((q, entry.text)); pendingQuestion = nil }
            case .status, .error: continue
            }
        }
        return pairs
    }

    func clearCodeLog() {
        codeLog = []
        codeUsage = nil
        errorText = nil
    }

    /// Back to listening after a segment ran mid-recording, already in the
    /// paused (amber) state rather than flashing "recording".
    func resumeListeningPaused() {
        status = .listening
        speechIdleTask?.cancel()
        speechActive = false
    }

    /// The single thing the panel colours itself by.
    var phase: AssistantPhase {
        switch status {
        case .idle: .ready
        case .listening: speechActive || transcript.isEmpty ? .recording : .paused
        case .thinking: .working
        case .answering: .done
        }
    }
    var accent: Color { phase.color }
    @Published var answer = ""
    /// A passage copied off the screen by voice. Deliberately NOT `answer`:
    /// the planner writes a running commentary there and finishes every plan
    /// with "Done.", which would wipe the text the moment it appeared. This
    /// sits underneath and survives, monospaced, because indentation in code
    /// is meaning rather than decoration.
    @Published var copiedPreview: String?
    @Published var errorText: String?
    @Published var collapsed = false
    /// Shrunk in place to a thin bar — mic, phase, nothing else. Distinct
    /// from `collapsed`, which tucks a dot into the screen corner.
    @Published var strip = false
    @Published var tab: AssistantTab = .ask
    /// Last dictation result (on the clipboard, paired with the capture if any).
    @Published var dictationText = ""
    /// Last region capture (saved to disk; on the clipboard, paired with the dictation if any).
    @Published var captureImage: NSImage?
    @Published var captureURL: URL?
    /// Where the preview came from. `.capture` is a region grab; the other
    /// two arrive via the + menu ("Files and folders"). A `.file` is anything
    /// that isn't an image — previewed by its Finder icon and copied as a
    /// file URL rather than pixels.
    enum AttachmentKind { case capture, image, file }
    @Published var attachmentKind: AttachmentKind = .capture
    /// Pictures the user dropped, pasted, or picked into the Ask tab so a
    /// question can be about them ("what's wrong in the second one?"). They
    /// ride along with every Ask until removed — captures stay on their own
    /// tab and never land here.
    struct AskAttachment: Identifiable, Equatable {
        let id = UUID()
        let image: NSImage
        let name: String
        static func == (a: AskAttachment, b: AskAttachment) -> Bool { a.id == b.id }
    }
    static let maxAskAttachments = 10
    @Published var askAttachments: [AskAttachment] = []
    @Published var askAttachmentsCollapsed = false
    /// Every answered question, newest first — survives closing Peeky.
    @Published var askHistory: [AskHistoryEntry] = []
    /// The Ask tab is showing the History list instead of the current Q&A.
    @Published var showingAskHistory = false
    /// The Q&A on screen came back from History: show its text even when
    /// answers are normally spoken rather than shown.
    @Published var restoredFromHistory = false
    @Published var historySearch = ""
    /// Reloaded from disk when the saved capture is edited in an external
    /// app (e.g. Preview.app's markup arrow) after being saved — nil until
    /// the file actually changes.
    @Published var editedCaptureImage: NSImage?
    /// Which version is on the clipboard once there are two to choose from.
    /// Defaults to the edited one, since that's what the user just changed.
    @Published var clipboardChoice: CaptureClipboardChoice = .edited
    /// The version that should actually ride the clipboard right now.
    var imageForClipboard: NSImage? {
        clipboardChoice == .edited ? (editedCaptureImage ?? captureImage) : captureImage
    }
    /// True while Peeky is reading an answer aloud.
    @Published var isSpeaking = false
    /// Break coach: whether it's on, the countdown label, and the check-in
    /// text while one is waiting to be answered.
    @Published var coachEnabled = true
    @Published var coachCountdown = "25:00"
    @Published var coachMessage: String?
    var onToggleCoach: (() -> Void)?
    var onCoachBreak: (() -> Void)?
    var onCoachSnooze: (() -> Void)?
    /// Whether the Ask tab shows replies as text instead of speaking them
    /// (⌥⌘C questions land here too). Off by default — Peeky reads replies
    /// aloud unless the user turns "Read Response" on to read them itself.
    /// Persisted so the choice sticks between launches.
    @Published var textOnlyMode: Bool = UserDefaults.standard.object(forKey: AssistantState.textOnlyModeKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(textOnlyMode, forKey: AssistantState.textOnlyModeKey) }
    }
    private static let textOnlyModeKey = "assistantTextOnlyMode"
    /// True while the panel is stretched taller to give a long answer more
    /// room, instead of leaving it all in a small scrolling area.
    @Published var size: PanelSize = .normal
    /// Whether there's already room for a long answer. Both the wide tall
    /// card and the half column are full height; only the short default
    /// card isn't.
    var isTall: Bool { size != .normal }
    /// True whenever a request is in flight or speech is playing — i.e. when
    /// the Stop button should be shown.
    var canStop: Bool { status == .thinking || status == .listening || isSpeaking }
    var onSubmit: ((String) -> Void)?
    /// Talk tab: a command for Peeky to carry out on the Mac.
    var onDo: ((String) -> Void)?
    var onStop: (() -> Void)?
    /// Re-copies the current capture + dictation pair to the clipboard.
    var onCopyAgain: (() -> Void)?
    /// Dismisses the capture preview (the file on disk is untouched) and
    /// stops watching it for external edits.
    var onDismissCapture: (() -> Void)?
    /// Opens the macOS file picker so a file or folder from this Mac can be
    /// dropped into the capture preview (the + menu on Capture + Dictate).
    var onAttachFile: (() -> Void)?
    /// The Ask tab's + menu: pick images for the attachment strip.
    var onAttachToAsk: (() -> Void)?
    /// History list actions; persistence lives with the controller.
    var onRestoreHistory: ((AskHistoryEntry) -> Void)?
    var onDeleteHistory: ((AskHistoryEntry) -> Void)?
    var onClearHistory: (() -> Void)?
    /// Files dropped on, or pasted into, the Ask tab.
    var onDropIntoAsk: (([URL]) -> Void)?
    var onPasteIntoAsk: (() -> Void)?
    /// Peeky Code: a folder or files dropped or picked for the project,
    /// re-reading it from disk after edits, letting it go, and asking.
    var onDropIntoCode: (([URL]) -> Void)?
    var onAttachCodeProject: (() -> Void)?
    var onAttachCodeImages: (() -> Void)?
    var onReloadCodeProject: (() -> Void)?
    var onRemoveCodeProject: (() -> Void)?
    var onAskCode: ((String) -> Void)?
    /// Reads the current answer aloud on demand, regardless of `textOnlyMode`.
    var onReadAloud: (() -> Void)?
    /// Mic button: starts recording (a question on the Ask tab, a dictation
    /// on Capture + Dictate), or stops and finishes it if already recording.
    var onToggleRecording: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onRestore: (() -> Void)?
    /// Left-edge chevron: shrinks to the strip, or grows back from it.
    var onToggleStrip: (() -> Void)?
    /// Sets the card size (half / normal / tall) and resizes the window to match.
    var onSetSize: ((PanelSize) -> Void)?
    /// Live corner-drag resize: called continuously with the cumulative drag
    /// translation, then once more with `nil` when the drag ends.
    var onResize: ((PanelResizeCorner, CGSize?) -> Void)?
}

/// Floating, non-activating panel styled after a Rode Wireless Pro transmitter:
/// a dark, rounded square with a status readout.
@MainActor
final class AssistantPanelController {
    let state = AssistantState()
    private var panel: NSPanel?
    /// Called just before the panel closes so in-flight work can be stopped.
    var onHide: (() -> Void)?

    func show(near point: NSPoint, on screen: NSScreen) {
        let panel = ensurePanel()
        if state.collapsed { expand() }
        let visible = screen.visibleFrame
        // Respect wherever the user dragged the panel — including onto another
        // display: only reposition when it isn't visible anywhere. A fresh
        // open starts at bottom-center of the given screen.
        let visibleSomewhere = panel.isVisible
            && NSScreen.screens.contains { panel.frame.intersects($0.visibleFrame) }
        if !visibleSomewhere {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - Self.expandedSize.width / 2,
                y: visible.minY + 120
            ))
        }
        panel.orderFrontRegardless()
    }

    /// Parks the panel in the top-right corner of `screen` — the resting spot
    /// for a fresh region capture, so the preview lands somewhere predictable
    /// and out of the way of what was just captured. Leaves the dot/strip
    /// states, keeps the current card size, and never shrinks a tall panel.
    func showInCorner(on screen: NSScreen) {
        let panel = ensurePanel()
        // Flip the flags directly instead of expand()/toggleStrip(), which
        // each animate — one instant frame change covers every start state.
        let wasSmall = state.collapsed || state.strip
        state.collapsed = false
        state.strip = false
        let visible = screen.visibleFrame
        let size: NSSize
        if !panel.isVisible || wasSmall {
            size = savedFrame?.size ?? Self.frameSize(for: state.size)
        } else {
            size = panel.frame.size
        }
        savedFrame = nil
        let margin: CGFloat = 12 - Self.glowMargin
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        // Snap, don't glide — the preview should be in the corner the instant
        // the mouse is released.
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        panel.orderFrontRegardless()
    }

    /// Opens the panel already shrunk to the one-line strip, parked at the
    /// bottom-center of `screen` — the resting state for a phone-driven TALK
    /// session, where the Mac panel is only glanced at, not worked in. The
    /// chevron on the strip still restores the full card.
    func showAsStrip(on screen: NSScreen) {
        let panel = ensurePanel()
        if state.collapsed { state.collapsed = false }
        if !state.strip {
            if panel.isVisible { savedFrame = panel.frame }
            state.strip = true
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.stripSize.width / 2,
            y: visible.minY + 16
        )
        panel.setFrame(NSRect(origin: origin, size: Self.stripSize), display: true, animate: panel.isVisible)
        panel.orderFrontRegardless()
    }

    // Card is 960x220 by default (960x520 when stretched tall via the header
    // button); the window carries an extra margin so the outer glow isn't
    // clipped. The user can also freely drag any corner — see `resize(_:)`.
    static let glowMargin: CGFloat = 24
    private static let expandedSize = NSSize(width: 960 + glowMargin * 2, height: 220 + glowMargin * 2)
    private static let tallSize = NSSize(width: 960 + glowMargin * 2, height: 520 + glowMargin * 2)
    /// Half the tall card's width, at its full height.
    private static let halfSize = NSSize(width: 480 + glowMargin * 2, height: 520 + glowMargin * 2)
    private static func frameSize(for size: PanelSize) -> NSSize {
        switch size {
        case .half: return halfSize
        case .normal: return expandedSize
        case .tall: return tallSize
        }
    }
    private static func height(for size: PanelSize) -> CGFloat { frameSize(for: size).height }
    private static let collapsedSize = NSSize(width: 56, height: 56)
    private static let stripSize = NSSize(width: 420 + glowMargin * 2, height: 52 + glowMargin * 2)
    private static let minPanelSize = NSSize(width: 480 + glowMargin * 2, height: 160 + glowMargin * 2)
    private static let maxPanelSize = NSSize(width: 1500, height: 1000)
    /// Full frame just before minimizing, so restoring puts it back exactly
    /// (including any manual corner-resize) rather than snapping to a preset.
    private var savedFrame: NSRect?
    private var resizeStartFrame: NSRect?
    /// Where on the bottom grip the pointer landed (screen y minus edge y),
    /// so an edge drag moves the edge by exactly the hand's motion.
    private var resizeGrabOffset: CGFloat?

    /// Shrinks the panel in place to a one-line bar, or restores it. The bar
    /// keeps the panel's top-right corner — where the chevron is — so it
    /// stays under the pointer; the corner dot (`minimize`) is for getting
    /// it out of the way.
    func toggleStrip() {
        guard let panel, !state.collapsed else { return }
        if state.strip {
            state.strip = false
            let size = savedFrame?.size ?? Self.expandedSize
            let screen = panel.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            var origin = NSPoint(x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height)
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
            panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        } else {
            savedFrame = panel.frame
            state.strip = true
            let origin = NSPoint(x: panel.frame.maxX - Self.stripSize.width, y: panel.frame.maxY - Self.stripSize.height)
            panel.setFrame(NSRect(origin: origin, size: Self.stripSize), display: true, animate: true)
        }
    }

    func minimize() {
        guard let panel, !state.collapsed else { return }
        savedFrame = state.strip ? (savedFrame ?? panel.frame) : panel.frame
        state.strip = false
        state.collapsed = true
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: visible.maxX - Self.collapsedSize.width - 12,
            y: visible.minY + 12
        )
        panel.setFrame(NSRect(origin: origin, size: Self.collapsedSize), display: true, animate: true)
    }

    func expand() {
        guard let panel, state.collapsed else { return }
        state.collapsed = false
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = savedFrame?.size ?? Self.expandedSize
        var origin = savedFrame?.origin ?? NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.minY + 12
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    /// Brings the panel to its full card: out of the corner dot, out of the
    /// strip, and stretched tall. Used when an answer is about to land that
    /// was asked from the phone — the user is looking at the Mac only to read
    /// it, so a dot or a one-line bar would hide the very thing they want.
    func presentFull(near point: NSPoint, on screen: NSScreen) {
        show(near: point, on: screen)
        if state.strip { toggleStrip() }
        growIfNeeded()
    }

    /// Stretches the panel taller (or back to normal) in place, growing
    /// upward so the bottom edge — closest to wherever the user is
    /// working — doesn't shift. Keeps whatever width the user last set.
    /// Grows the panel if it isn't already tall. Used when something arrives
    /// that has to be read rather than glanced at — a copied passage lands in
    /// a panel sized for one line of status and is otherwise clipped away
    /// entirely, header showing and nothing beneath it.
    /// Never changes a layout the user chose that already has room: the half
    /// column is full height and stays a half column.
    func growIfNeeded() {
        guard !state.isTall else { return }
        setSize(.tall)
    }

    func setSize(_ size: PanelSize) {
        guard let panel, !state.collapsed, !state.strip else { return }
        let wasHalf = state.size == .half
        state.size = size
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let target = Self.frameSize(for: size)
        let height = target.height
        // Width only changes when entering or leaving the half column; the
        // other two keep whatever width the user dragged out. The right edge
        // stays put so a panel parked at the screen edge stays there.
        let width = (size == .half || wasHalf) ? target.width : panel.frame.width
        var origin = panel.frame.origin
        origin.x = panel.frame.maxX - width
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(origin.y, visible.maxY - height - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height),
                        display: true, animate: true)
    }

    /// Live corner-drag resize. `translation` is the cumulative drag offset
    /// from where this drag started (SwiftUI, down-positive); `nil` means the
    /// drag just ended. The opposite corner stays anchored in place.
    func resize(_ corner: PanelResizeCorner, translation: CGSize?) {
        guard let panel, !state.collapsed, !state.strip else { return }
        guard let translation else {
            resizeStartFrame = nil
            resizeGrabOffset = nil
            // Keep the size switch honest after a manual drag: snap to the
            // nearest preset.
            let f = panel.frame
            if f.width < (Self.halfSize.width + Self.expandedSize.width) / 2 {
                state.size = .half
            } else {
                state.size = f.height > (Self.expandedSize.height + Self.tallSize.height) / 2 ? .tall : .normal
            }
            return
        }
        let start = resizeStartFrame ?? panel.frame
        resizeStartFrame = start

        let anchor = corner.anchor(in: start)
        let original = corner.point(in: start)
        let dragged: NSPoint
        if corner.isEdge {
            // The grip rides on the edge it moves, so a gesture translation
            // measured in its own space chases itself and stutters. Track the
            // pointer in screen space instead — the edge simply follows the
            // mouse, keeping the grab offset from where the drag began.
            let mouse = NSEvent.mouseLocation
            if resizeGrabOffset == nil { resizeGrabOffset = mouse.y - original.y }
            dragged = NSPoint(x: original.x, y: mouse.y - (resizeGrabOffset ?? 0))
        } else {
            // Flip the y sign: SwiftUI's translation is down-positive,
            // AppKit's window coordinates are up-positive.
            dragged = NSPoint(x: original.x + translation.width, y: original.y - translation.height)
        }

        let width = min(max(abs(dragged.x - anchor.x), Self.minPanelSize.width), Self.maxPanelSize.width)
        let height = min(max(abs(dragged.y - anchor.y), Self.minPanelSize.height), Self.maxPanelSize.height)
        let x = dragged.x >= anchor.x ? anchor.x : anchor.x - width
        // The bottom edge always hangs below its (top) anchor, even if the
        // pointer overshoots above it.
        let y = corner.isEdge || dragged.y < anchor.y ? anchor.y - height : anchor.y

        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let clampedX = min(max(x, visible.minX), visible.maxX - width)
        let clampedY = min(max(y, visible.minY), visible.maxY - height)

        let frame = NSRect(x: clampedX, y: clampedY, width: width, height: height)
        guard frame != panel.frame else { return }
        // No implicit animation: the frame must land on the very event that
        // moved the pointer or the edge lags a beat behind the hand.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(frame, display: true)
        NSAnimationContext.endGrouping()
    }

    func hide() {
        onHide?()
        panel?.orderOut(nil)
        state.status = .idle
        state.transcript = ""
        state.answer = ""
        state.errorText = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect? { panel?.frame }
    /// The display the panel is showing on — where the user has chosen to work.
    var screen: NSScreen? {
        guard let panel, panel.isVisible else { return nil }
        return panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let content = AssistantPanelView(state: state)
        let hosting = NSHostingController(rootView: content)
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(Self.expandedSize)
        state.onDismiss = { [weak self] in self?.hide() }
        state.onMinimize = { [weak self] in self?.minimize() }
        state.onRestore = { [weak self] in self?.expand() }
        state.onToggleStrip = { [weak self] in self?.toggleStrip() }
        state.onSetSize = { [weak self] size in self?.setSize(size) }
        state.onResize = { [weak self] corner, translation in self?.resize(corner, translation: translation) }
        panel.onCancel = { [weak self] in
            guard let self, self.state.canStop else { return false }
            self.state.onStop?()
            return true
        }
        // Track which display the panel lives on, including hand drags, so
        // the phone's screen switch can follow reality.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteScreenChange() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteScreenChange() }
        }
        self.panel = panel
        return panel
    }

    // MARK: - Display switching (the phone's SCREEN lever)

    /// Fires with the 1-based index of the display the panel is on whenever
    /// that changes (or nil when hidden). Indexes follow `NSScreen.screens`,
    /// where the built-in display is first when present.
    var onScreenChange: ((Int?) -> Void)?
    private var lastReportedScreen: Int?
    /// Where the panel last sat on each display, keyed by display ID, so
    /// flipping back lands it exactly where it was left.
    private var framePerDisplay: [CGDirectDisplayID: NSRect] = [:]

    /// 1-based index of the display the panel is currently on, or nil.
    var currentScreenIndex: Int? {
        guard let screen else { return nil }
        return NSScreen.screens.firstIndex(of: screen).map { $0 + 1 }
    }

    private func noteScreenChange() {
        guard let panel, panel.isVisible, let screen else { return }
        if let id = Self.displayID(of: screen) { framePerDisplay[id] = panel.frame }
        let index = currentScreenIndex
        guard index != lastReportedScreen else { return }
        lastReportedScreen = index
        onScreenChange?(index)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Moves the panel to display `index` (1-based). Restores wherever it
    /// last sat on that display; the first visit lands bottom-centre. Keeps
    /// the current card size and leaves dot/strip states alone. Returns the
    /// screen it landed on, or nil when there is no such display.
    @discardableResult
    func move(toScreenIndex index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard index >= 1, index <= screens.count else { return nil }
        let target = screens[index - 1]
        let panel = ensurePanel()
        if let current = screen, let id = Self.displayID(of: current) { framePerDisplay[id] = panel.frame }
        if state.collapsed { expand() }
        let visible = target.visibleFrame
        let size = panel.frame.size
        var origin: NSPoint
        if let id = Self.displayID(of: target), let saved = framePerDisplay[id], saved.size == size {
            origin = saved.origin
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: panel.isVisible)
        panel.orderFrontRegardless()
        noteScreenChange()
        return target
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Return true to consume Esc (e.g. to stop an in-flight answer) instead of closing.
    var onCancel: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        orderOut(nil)
    }
}

struct AssistantPanelView: View {
    @ObservedObject var state: AssistantState
    @State private var typedQuestion = ""
    @FocusState private var fieldFocused: Bool
    @State private var breathing = false
    @State private var resizeHoverCorner: PanelResizeCorner?

    var body: some View {
        Group {
            if state.collapsed {
                collapsedDot
            } else if state.strip {
                stripBar
            } else {
                expandedPanel
            }
        }
        .onExitCommand { state.onDismiss?() }
    }

    /// The one-line form of the panel: the chevron to grow back, the phase
    /// indicator (bars while recording, amber pause, green tick), the mic
    /// and — while something is in flight — Stop. Enough to see that words
    /// are being heard and to end the recording, and nothing more.
    private var stripBar: some View {
        let phase = state.phase
        return HStack(spacing: 12) {
            Group {
                if phase == .recording {
                    RecordingBars(color: phase.color)
                } else {
                    Image(systemName: phase.icon)
                        .symbolEffect(.pulse, isActive: phase == .working)
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(phase.color)
            .frame(width: 28, height: 20)
            Text(phase.label)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(phase.color)
            Text(phaseHint)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if state.micLive { recBadge }
            micIndicator
            if state.canStop && state.status != .listening {
                stopButton
            }
            edgeChevron(expanded: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.094, green: 0.094, blue: 0.098))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(phase.color.opacity(phase == .ready ? 0.05 : 0.16))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(phase.color.opacity(0.85), lineWidth: phase == .recording || phase == .paused ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .compositingGroup()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(phase.color.opacity(breathing ? (phase == .recording ? 0.6 : 0.35) : 0.14))
                .blur(radius: 14)
                .animation(.easeInOut(duration: phase == .recording ? 0.9 : 2.2)
                    .repeatForever(autoreverses: true), value: breathing)
        )
        .padding(AssistantPanelController.glowMargin)
        .onAppear { breathing = true }
        .onDisappear { breathing = false }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    /// The chevron on the right edge: points outward to shrink the panel to
    /// its strip, back inward to grow it again.
    private func edgeChevron(expanded: Bool) -> some View {
        Button {
            state.onToggleStrip?()
        } label: {
            Image(systemName: expanded ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(state.accent)
                .frame(width: 26, height: expanded ? 64 : 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.accent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(state.accent.opacity(0.6), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(expanded ? "Shrink to a strip" : "Expand the panel")
    }

    /// Three-segment size switch in the header: half · normal · tall. The
    /// current size is lit; click another to jump straight to it. Sits
    /// left of Minimize and Close so the row reads smallest-to-gone.
    private var sizeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(PanelSize.allCases, id: \.rawValue) { size in
                let on = state.size == size
                Button {
                    state.onSetSize?(size)
                } label: {
                    Image(systemName: size.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.4))
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(on ? Color.white.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(size.label)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        )
        .padding(.trailing, 4)
    }

    private var collapsedDot: some View {
        Button(action: { state.onRestore?() }) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                Circle()
                    .fill(state.accent)
                    .frame(width: 14, height: 14)
                    .shadow(color: state.accent.opacity(0.8), radius: 5)
                if state.micLive {
                    RecRing()
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                tabBar
                if state.micLive { recBadge }
                Spacer()
                sizeSwitch
                headerButton("arrow.down.right.and.arrow.up.left", help: "Minimize to corner") {
                    state.onMinimize?()
                }
                headerButton("xmark", help: "Close") {
                    state.onDismiss?()
                }
            }
            // Thin rule under the tabs, as a terminal draws under its tab row.
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            phaseStrip
            if let message = state.coachMessage {
                coachCard(message)
                    .animation(.easeInOut(duration: 0.25), value: state.coachMessage)
            }
            Group {
                switch state.tab {
                case .ask:
                    topInputRow
                    if state.showingAskHistory {
                        askHistoryView
                    } else {
                        askAttachmentsStrip
                        transcriptView
                        answerView
                    }
                case .talk:
                    topInputRow
                    if state.status == .listening { transcriptView }
                    talkLogView
                case .captureDictate:
                    captureDictateTab
                case .code:
                    topInputRow
                    if !state.codeImages.isEmpty { codeImagesRow }
                    codeProjectCard
                    if state.codeShowingFiles, let project = state.codeProject {
                        codeFileList(project)
                    } else if let path = state.codeFocusedFile, let file = state.codeProject?.file(at: path) {
                        codeFileViewer(file)
                    }
                    // With a file or the list up and nothing asked yet, the
                    // empty log's hint would steal half the height.
                    if !state.codeLog.isEmpty || (!state.codeShowingFiles && state.codeFocusedFile == nil) {
                        codeLogView
                    }
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                guard state.tab == .ask || state.tab == .code else { return false }
                return handleAskDrop(providers)
            }
            .onPasteCommand(of: [.image, .fileURL, .png, .tiff]) { _ in
                if state.tab == .ask { state.onPasteIntoAsk?() }
            }
            Spacer(minLength: 0)
            bottomBar
        }
        // Extra room on the right for the edge chevron.
        .padding(.leading, 18)
        .padding(.trailing, 36)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: state.size)
        .background(
            ZStack {
                // Flat, near-black terminal background.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.094, green: 0.094, blue: 0.098))
                // A wash of the phase colour from the top, strong enough while
                // recording that the whole panel reads as "live" at a glance.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [state.accent.opacity(state.phase == .recording ? 0.22 : 0.10), .clear],
                            center: .top,
                            startRadius: 0,
                            endRadius: 320
                        )
                    )
            }
        )
        // Crisp rim in the phase colour, heavier while recording.
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            state.accent.opacity(0.9),
                            state.accent.opacity(0.4),
                            state.accent.opacity(0.9),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: state.phase == .recording || state.phase == .paused ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .trailing) { edgeChevron(expanded: true).padding(.trailing, 3) }
        .overlay(alignment: .bottom) { bottomEdgeHandle }
        .overlay(alignment: .topLeading) { resizeHandle(.topLeading) }
        .overlay(alignment: .topTrailing) { resizeHandle(.topTrailing) }
        .overlay(alignment: .bottomLeading) { resizeHandle(.bottomLeading) }
        .overlay(alignment: .bottomTrailing) { resizeHandle(.bottomTrailing) }
        .compositingGroup()
        // Soft outer halo (Spotlight-style) drawn as a blurred rounded rect so
        // the corners stay round, plus a grounding drop shadow.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(state.accent.opacity(breathing ? (state.phase == .recording ? 0.6 : 0.42) : 0.16))
                .blur(radius: breathing ? 18 : 10)
                // The halo breathes slowly at rest and quickly while recording,
                // so a live mic is visible even from across the room.
                .animation(.easeInOut(duration: state.phase == .recording ? 0.9 : 2.2)
                    .repeatForever(autoreverses: true), value: breathing)
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .blur(radius: 10)
                .offset(y: 6)
        )
        .padding(AssistantPanelController.glowMargin)
        .onAppear { breathing = true }
        .onDisappear { breathing = false }
        .animation(.easeInOut(duration: 0.35), value: state.phase)
    }

    // Tab row along the top edge, drawn the way a code editor draws its
    // terminal tabs: plain text, the active one lifted on a soft rectangle.
    private var tabBar: some View {
        HStack(spacing: 4) {
            if state.size == .half {
                // The half column can't fit three labels, and bare icons
                // were a guessing game — so one dropdown names the current
                // tab and lists the other two.
                tabDropdown
            } else {
                ForEach(AssistantTab.allCases, id: \.self) { tab in
                    Button {
                        state.tab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: state.tab == tab ? .semibold : .regular, design: .monospaced))
                        }
                        .help(tab.rawValue)
                        .foregroundStyle(state.tab == tab ? .white : Color.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(state.tab == tab ? Color.white.opacity(0.13) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var tabDropdown: some View {
        Menu {
            ForEach(AssistantTab.allCases, id: \.self) { tab in
                Button {
                    state.tab = tab
                } label: {
                    if state.tab == tab {
                        Label(tab.shortName, systemImage: "checkmark")
                    } else {
                        Label(tab.shortName, systemImage: tab.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(state.tab.shortName)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.13))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.tab.rawValue)
    }

    /// The one line that tells the user where they are in the voice flow —
    /// and, above all, when they may speak a command. Red with moving bars
    /// while words are coming in; amber the moment they stop; purple while
    /// Peeky works; green when it's finished. The whole panel shifts hue
    /// with it, but this strip says so in words.
    private var phaseStrip: some View {
        let phase = state.phase
        return HStack(spacing: 12) {
            Group {
                if phase == .recording {
                    RecordingBars(color: phase.color)
                } else if phase == .working {
                    Image(systemName: phase.icon)
                        .symbolEffect(.pulse, isActive: true)
                } else {
                    Image(systemName: phase.icon)
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(phase.color)
            .frame(width: 28, height: 20)
            Text(phase.label)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(phase.color)
            Text(phase == .done && state.chaining
                 ? "still listening — ask your next question, or press STOP"
                 : phase == .paused && (state.tab == .ask || state.tab == .code)
                 ? "pause and Peeky answers — keep asking, or press STOP"
                 : phase.hint)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if phase == .paused {
                Text("STOP when done")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(phase.color))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(phase.color.opacity(phase == .ready ? 0.06 : 0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(phase.color.opacity(phase == .ready ? 0.2 : 0.55), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    // Capture + Dictate tab: the latest ⌃⌥X region grab centered on the left,
    // the latest ⌥⌘V dictation on the right. Both are kept on the clipboard as
    // one item (image + text) so a single ⌘V pastes whichever the app accepts.
    private var captureDictateTab: some View {
        Group {
            if state.captureImage != nil {
                // Once there's a capture it takes center stage, with the
                // dictation (live transcript or final text) directly beneath.
                VStack(spacing: 8) {
                    captureColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    dictationUnderImage
                }
            } else if state.size == .half {
                // The narrow column stacks the two halves instead.
                VStack(spacing: 14) {
                    captureColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                    dictateColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    captureColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                    dictateColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Compact dictation strip shown under the centered capture preview.
    private var dictationUnderImage: some View {
        HStack(alignment: .top, spacing: 8) {
            if state.status == .listening {
                Image(systemName: state.phase == .paused ? "pause.fill" : "waveform")
                    .foregroundStyle(state.accent)
                    .symbolEffect(.pulse, isActive: state.phase == .recording)
                Text(state.transcript.isEmpty
                     ? "Listening… speak now. Click the mic again when you're done."
                     : state.transcript)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(state.transcript.isEmpty ? .white.opacity(0.6) : .white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = state.errorText {
                // A fresh recording attempt just failed — say so instead of
                // silently falling back to whatever old text is on screen.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.dictationText.isEmpty {
                Image(systemName: "mic.badge.plus")
                    .foregroundStyle(.white.opacity(0.4))
                Text("Click the mic (or hold ⌥⌘V) and speak — your words appear here and go on the clipboard with the image.")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: state.status == .thinking ? "sparkles" : "checkmark.circle.fill")
                    .foregroundStyle(state.status == .thinking ? .yellow : .green)
                ScrollView {
                    Text(state.dictationText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 40)
                Button {
                    state.dictationText = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                Button {
                    state.onCopyAgain?()
                } label: {
                    Label("Copy again", systemImage: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dictateColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.status == .listening {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: state.phase == .paused ? "pause.fill" : "waveform")
                        .foregroundStyle(state.accent)
                        .symbolEffect(.pulse, isActive: state.phase == .recording)
                    if state.transcript.isEmpty {
                        Text("Listening… speak now. Click the mic again (or release ⌥⌘V) when done.")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        ScrollView {
                            Text(state.transcript)
                                .font(.system(size: 17, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else if let error = state.errorText {
                // A fresh recording attempt just failed — say so instead of
                // silently falling back to whatever old text is on screen.
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.dictationText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Click the mic below, or hold ⌥⌘V (or tap DICTATE on your phone) and speak.\nYour words are tidied up and copied to the clipboard.")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(state.dictationText)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(state.captureImage == nil
                         ? "On your clipboard — paste anywhere with ⌘V"
                         : "Text + image on your clipboard — paste with ⌘V")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.dictationText = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    Button {
                        state.onCopyAgain?()
                    } label: {
                        Label("Copy again", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                }
            }
        }
    }

    private var captureColumn: some View {
        VStack(spacing: 6) {
            if let image = state.captureImage {
                Group {
                    if let edited = state.editedCaptureImage {
                        HStack(spacing: 10) {
                            capturePreviewThumbnail(
                                image: image, title: "Original", fileName: state.captureURL?.lastPathComponent,
                                isSelected: state.clipboardChoice == .original,
                                help: "The capture as originally grabbed, kept in memory — saving in Preview doesn't touch this.",
                                onOpen: nil,
                                onSelect: { selectClipboardChoice(.original) }
                            )
                            capturePreviewThumbnail(
                                image: edited, title: "Edited", fileName: state.captureURL?.lastPathComponent,
                                isSelected: state.clipboardChoice == .edited,
                                help: "Reloaded from disk after your changes were saved in Preview. Click to reopen it.",
                                onOpen: { if let url = state.captureURL { NSWorkspace.shared.open(url) } },
                                onSelect: { selectClipboardChoice(.edited) }
                            )
                        }
                    } else if state.attachmentKind == .file {
                        // Not an image: the Finder icon at a sane size, with
                        // the name, rather than a 256pt icon blown up to fill.
                        VStack(spacing: 10) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 96, height: 96)
                            Text(state.captureURL?.lastPathComponent ?? "")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(state.captureURL?.deletingLastPathComponent().path
                                    .replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = state.captureURL { NSWorkspace.shared.open(url) }
                        }
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                            .onTapGesture {
                                if let url = state.captureURL { NSWorkspace.shared.open(url) }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    // Dismisses the preview only — the file already
                    // saved to disk (VIRADETH_RESUME) is untouched.
                    Button {
                        state.onDismissCapture?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Dismiss preview (file is still saved)")
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(captureStatusText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Press ⌃⌥X (or tap CAPTURE on your phone) and drag out a region.\nThe capture is saved, copied, and previewed here.")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                    Text("Or click + below to add a file or folder from this Mac.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One thumbnail in the original/edited pair, with a checkbox beneath it
    /// selecting which version rides the clipboard. `onOpen` is nil for the
    /// original, which has no file of its own to reopen once Preview has
    /// overwritten the capture on disk with the edited version.
    private func capturePreviewThumbnail(
        image: NSImage, title: String, fileName: String?, isSelected: Bool, help: String,
        onOpen: (() -> Void)?, onSelect: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.cyan.opacity(0.7) : Color.white.opacity(0.2),
                                  lineWidth: isSelected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { onOpen?() }
                .help(help)
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .cyan : .white.opacity(0.4))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .buttonStyle(.plain)
            .help("Use this version for the clipboard")
            if let fileName {
                Text(fileName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Selects which version (original vs. edited) rides the clipboard, and
    /// re-copies immediately so the choice takes effect right away.
    private func selectClipboardChoice(_ choice: CaptureClipboardChoice) {
        state.clipboardChoice = choice
        state.onCopyAgain?()
    }

    private var captureStatusText: String {
        let name = state.captureURL?.lastPathComponent ?? "Saved"
        switch state.attachmentKind {
        case .image: return "\(name) — added from this Mac, on your clipboard, click to open"
        case .file: return "\(name) — added from this Mac, copied as a file, click to open"
        case .capture: break
        }
        guard state.editedCaptureImage != nil else {
            return "\(name) — on your clipboard, click to open"
        }
        let which = state.clipboardChoice == .edited ? "Edited version" : "Original"
        return "\(which) on your clipboard — click the Edited thumbnail to reopen in Preview"
    }

    // Claude-style: big input field on top, mic status at top-right.
    private var topInputRow: some View {
        HStack(spacing: 10) {
            if state.tab == .ask { historyButton }
            ZStack(alignment: .leading) {
                if typedQuestion.isEmpty {
                    Text(inputPlaceholder)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
                TextField("", text: $typedQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(submit)
            }
        }
        .padding(.top, 4)
    }

    /// Terminal-style log for the Talk tab: `❯ HH:mm:ss command` lines in the
    /// accent colour, results indented under them. ⌘K clears it.
    private var talkLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.talkLog.isEmpty {
                Text("Commands and what Peeky did with them show up here, timestamped. ⌘K clears.")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 2)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(state.talkLog) { entry in
                                talkLogLine(entry).id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .onChange(of: state.talkLog.count) { _ in
                        if let last = state.talkLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = state.talkLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        state.clearTalkLog()
                    } label: {
                        Text("clear ⌘K")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the log (⌘K)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            // ⌘K, the terminal's "clear", while the panel has the keyboard.
            Button("") { state.clearTalkLog() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func talkLogLine(_ entry: TalkLogEntry) -> some View {
        let stamp = Self.logClock.string(from: entry.time)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stamp)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            switch entry.kind {
            case .command:
                Text("❯")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AssistantPhase.working.color)
                Text(entry.text)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            case .status:
                Text(entry.text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(entry.text.lowercased().hasPrefix("done") ? AssistantPhase.done.color : .white.opacity(0.78))
                    .padding(.leading, 18)
            case .error:
                Text(entry.text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.leading, 18)
            case .copied:
                copiedLogBlock(entry)
                    .padding(.leading, 18)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var expandedCopies: Set<UUID> = []

    // MARK: Peeky Code

    /// The dropped project, or a drop zone inviting one. With a project:
    /// its name, size in files and tokens, and — after the first question —
    /// whether the last one was served from the prompt cache.
    @ViewBuilder
    private var codeProjectCard: some View {
        if state.codeLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the project…")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(codeCardBackground)
        } else if let project = state.codeProject {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if state.codeFocusedFile != nil {
                                state.codeFocusedFile = nil
                                state.codeShowingFiles = true
                            } else {
                                state.codeShowingFiles.toggle()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                                .rotationEffect(.degrees(state.codeShowingFiles ? 90 : 0))
                            Image(systemName: "folder.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.98))
                            Text(project.name)
                                .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let path = state.codeFocusedFile {
                                // Breadcrumb: StageTimePNW › App › CustomTabBar.swift
                                ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { index, part in
                                    Text("›")
                                        .foregroundStyle(.white.opacity(0.35))
                                    Text(String(part))
                                        .fontWeight(index == path.split(separator: "/").count - 1 ? .bold : .medium)
                                        .foregroundStyle(.white.opacity(index == path.split(separator: "/").count - 1 ? 1 : 0.7))
                                        .lineLimit(1)
                                }
                                .font(.system(size: 13.5, design: .monospaced))
                            } else {
                                Text(project.summaryLine)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(state.codeFocusedFile != nil ? "Back to the file list"
                          : state.codeShowingFiles ? "Hide the file list" : "Show every file in the project")
                    Spacer(minLength: 0)
                    if let path = state.codeFocusedFile {
                        codeCardButton("arrow.up.forward.app", help: "Open this file in your editor") {
                            NSWorkspace.shared.open(project.root.appendingPathComponent(path))
                        }
                        codeCardButton("xmark", help: "Close the file — back to the whole project") {
                            withAnimation(.easeInOut(duration: 0.18)) { state.codeFocusedFile = nil }
                        }
                    } else {
                        codeCardButton("arrow.clockwise", help: "Re-read the project from disk (after editing files)") {
                            state.onReloadCodeProject?()
                        }
                        codeCardButton("xmark", help: "Remove the project") {
                            state.onRemoveCodeProject?()
                        }
                    }
                }
                .help(project.root.path)
                HStack(spacing: 6) {
                    if let usage = state.codeUsage {
                        Image(systemName: usage.hitCache ? "bolt.fill" : "bolt.slash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(usage.hitCache ? AssistantPhase.done.color : .white.opacity(0.4))
                        Text(codeUsageLine(usage))
                    } else if project.truncated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                        Text("Too big to send whole — \(project.skippedFiles.count) files left out")
                    } else {
                        Text(codeSkippedLine(project))
                    }
                    Spacer(minLength: 12)
                    if let live = state.codeLiveCost {
                        codeCostPill(live.sinceUSD >= 0.005
                                     ? "Cost: \(codeCostString(live.settledUSD)) + \(codeCostString(live.sinceUSD)) today"
                                     : "Cost: \(codeCostString(live.settledUSD)) this month",
                                     help: "Spend on Peeky's API key this month: what Anthropic has billed for closed days, plus today's tokens at list prices (the bill catches up at midnight UTC).")
                    } else if state.codeSpentUSD > 0 {
                        codeCostPill("Cost: \(codeCostString(state.codeSpentUSD))",
                                     help: "Estimated from the tokens each answer reported, at Sonnet list prices (cache reads at a tenth). Running total since install. Add an Admin key to Keychain (account anthropic-admin) for the real figure.")
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(codeCardBackground)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Drop a project folder here")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.85))
                Text("Swift, Python, HTML/CSS, JavaScript, Java… Peeky reads the whole thing and answers questions about it. The project is prompt-cached, so follow-up questions cost about a tenth of the first.")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    state.onAttachCodeProject?()
                } label: {
                    Text("choose folder…")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Color.white.opacity(0.18))
            )
        }
    }

    private var codeCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    /// Every file in the project, grouped under its folder — Finder's list
    /// view. Click one to open it in the preview.
    private func codeFileList(_ project: CodeProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(project.filesByFolder, id: \.folder) { group in
                    if !group.folder.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .semibold))
                            Text(group.folder + "/")
                        }
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    }
                    ForEach(group.files, id: \.path) { file in
                        codeFileRow(file, indented: !group.folder.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(codeCardBackground)
    }

    private func codeFileRow(_ file: CodeProject.File, indented: Bool) -> some View {
        let lines = file.text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.codeFocusedFile = file.path }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(lines) lines")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.leading, indented ? 18 : 0)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(file.path)")
    }

    /// One file, the way the capture preview shows one image: line
    /// numbers down the left, scrollable both ways, selectable.
    private func codeFileViewer(_ file: CodeProject.File) -> some View {
        // One row per line, rendered lazily: a single giant Text goes blank
        // once it passes the ~16K px layer limit on big files.
        let lines = file.text.components(separatedBy: "\n")
        let gutter = CGFloat(max(2, String(lines.count).count)) * 8 + 6
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { state.codeViewerCollapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .rotationEffect(.degrees(state.codeViewerCollapsed ? 0 : 90))
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("\(lines.count) lines")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.codeViewerCollapsed ? "Show the file" : "Collapse the file preview")
            if !state.codeViewerCollapsed {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.white.opacity(0.3))
                                    .frame(width: gutter, alignment: .trailing)
                                Text(lines[index].isEmpty ? " " : lines[index])
                                    .foregroundStyle(.white.opacity(0.9))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 12.5, design: .monospaced))
                            .padding(.vertical, 1)
                        }
                    }
                    .padding([.horizontal, .bottom], 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(codeCardBackground)
        .id(file.path)
    }

    /// Pictures attached to the code question, by name only — the code is
    /// the main thing on this tab, so no thumbnails.
    private var codeImagesRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(state.codeImages) { item in
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            state.codeImages.removeAll { $0.id == item.id }
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this image")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            Spacer(minLength: 0)
            Text("sent with every question")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 4)
    }

    private func codeCostString(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.3f", usd) : String(format: "$%.2f", usd)
    }

    private func codeCostPill(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .help(help)
    }

    private func codeCardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func codeUsageLine(_ usage: AnthropicService.Usage) -> String {
        if usage.hitCache {
            return "last question: \(CodeProject.compact(usage.cacheRead)) tokens from cache (≈10% price) · \(CodeProject.compact(usage.input)) fresh"
        }
        if usage.cacheWrite > 0 {
            return "last question: \(CodeProject.compact(usage.cacheWrite)) tokens cached for the next ~5 min · follow-ups are cheap"
        }
        return "last question: \(CodeProject.compact(usage.input)) tokens (project too small to cache)"
    }

    private func codeSkippedLine(_ project: CodeProject) -> String {
        var parts: [String] = []
        if !project.skippedFolders.isEmpty {
            parts.append("skipped " + project.skippedFolders.prefix(4).joined(separator: ", ")
                         + (project.skippedFolders.count > 4 ? "…" : ""))
        }
        if !project.skippedFiles.isEmpty {
            parts.append("\(project.skippedFiles.count) non-text or oversized file\(project.skippedFiles.count == 1 ? "" : "s") left out")
        }
        return parts.isEmpty ? "every file included — ask away" : parts.joined(separator: " · ")
    }

    private var codeLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.codeLog.isEmpty {
                Text(state.codeProject == nil
                     ? "Questions about the project and Peeky's answers show up here. ⌘K clears."
                     : "Try: “what does this app do?” · “find the bug in the tab bar” · “add a dark mode toggle”")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 2)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(state.codeLog) { entry in
                                codeLogLine(entry).id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        // Room for the "clear ⌘K" pill in the corner.
                        .padding(.trailing, 90)
                    }
                    .onChange(of: state.codeLog.count) { _ in
                        if let last = state.codeLog.last { proxy.scrollTo(last.id, anchor: .top) }
                    }
                    .onAppear {
                        if let last = state.codeLog.last { proxy.scrollTo(last.id, anchor: .top) }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        state.clearCodeLog()
                    } label: {
                        Text("clear ⌘K")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the conversation (⌘K) — the project stays")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Button("") { state.clearCodeLog() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private func codeLogLine(_ entry: CodeLogEntry) -> some View {
        let stamp = Self.logClock.string(from: entry.time)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stamp)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            switch entry.kind {
            case .question:
                Text("❯")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(AssistantPhase.working.color)
                Text(entry.text)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            case .answer:
                Text(entry.text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
            case .status:
                Text(entry.text)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 18)
            case .error:
                Text(entry.text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.leading, 18)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A copied passage inline in the log, like `cat` output under the command
    /// that produced it: a one-line summary, the first few lines dimmed, and
    /// a toggle for the rest.
    private func copiedLogBlock(_ entry: TalkLogEntry) -> some View {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let expanded = expandedCopies.contains(entry.id)
        let previewCount = 4
        let shown = expanded ? lines : Array(lines.prefix(previewCount))
        let hidden = lines.count - shown.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    if expanded { expandedCopies.remove(entry.id) } else { expandedCopies.insert(entry.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("copied \(entry.text.count) chars · \(lines.count) line\(lines.count == 1 ? "" : "s") — on your clipboard")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(AssistantPhase.done.color.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse" : "Show all lines")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Text("⧉ copy again")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Put it back on the clipboard")
            }
            Group {
                if expanded {
                    ScrollView([.vertical, .horizontal]) {
                        Text(shown.joined(separator: "\n"))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text(shown.joined(separator: "\n"))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(previewCount)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle().fill(AssistantPhase.done.color.opacity(0.35)).frame(width: 2).padding(.leading, 4)
            }
            if !expanded, hidden > 0 {
                Button {
                    expandedCopies.insert(entry.id)
                } label: {
                    Text("… \(hidden) more line\(hidden == 1 ? "" : "s")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
            }
        }
    }

    /// Strips the indentation the passage shared on the page, so it hangs
    /// from the log's own margin instead of floating mid-panel.
    static func dedent(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        guard indent > 0 else { return text }
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .joined(separator: "\n")
    }

    private static let logClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var phaseHint: String {
        switch state.phase {
        case .paused: "say a command, or press STOP"
        case .done where state.chaining: "done — say the next command, or press STOP"
        default: state.phase.hint
        }
    }

    private var inputPlaceholder: String {
        switch state.tab {
        case .talk: ""
        case .code: state.codeProject == nil ? "Drop a project folder here, then ask…"
            : "Ask about \(state.codeFocusedFile.map { ($0 as NSString).lastPathComponent } ?? state.codeProject?.name ?? "your code")…"
        default: "Ask Peeky anything…"
        }
    }

    /// Mic in the bottom bar: click to start recording, click again to stop.
    /// What it records follows the tab — a question on Ask, a dictation on
    /// Capture + Dictate, a command to carry out on Talk. (⌥⌘C / ⌥⌘V still
    /// work as system-wide shortcuts.)
    private var recBadge: some View {
        RecBadge(since: state.micLiveSince)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var micIndicator: some View {
        let listening = state.status == .listening
        let idleHelp: String = switch state.tab {
        case .ask: "Ask by voice"
        case .talk: "Say what you want Peeky to do"
        case .captureDictate: "Start dictation"
        case .code: "Ask about your code by voice"
        }
        return Button {
            state.onToggleRecording?()
        } label: {
            Image(systemName: listening ? (state.phase == .paused ? "pause.fill" : "waveform") : "mic")
                .font(.system(size: listening ? 19 : 15, weight: .medium))
                .foregroundStyle(listening ? state.accent : state.accent.opacity(0.85))
                .symbolEffect(.pulse, isActive: state.phase == .recording)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(listening ? state.accent.opacity(0.22) : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(listening ? "Stop recording" : idleHelp)
    }

    /// Labeled toggle in the bottom bar: on the Ask tab, switches whether the
    /// user reads replies as text (on) or Peeky speaks them aloud (off, the
    /// default, matching the ⌥⌘C flow).
    private var readAloudToggle: some View {
        Button {
            state.textOnlyMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.textOnlyMode ? "text.bubble.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Read Response")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(state.textOnlyMode ? state.accent.opacity(0.9) : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(state.textOnlyMode
                    ? Color.white.opacity(0.12)
                    : Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
        .help(state.textOnlyMode
              ? "Text only — click to have Peeky read replies aloud instead"
              : "Reading replies aloud — click to read them as text instead")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if state.tab == .captureDictate || state.tab == .ask || state.tab == .code {
                addMenu
            }
            // Shell-prompt readout: `peeky on talk ❯` — the segments coloured
            // as a prompt colours them, the chevron in the phase colour.
            // Each word is pinned to one line so a narrow panel never breaks
            // "peeky" into "cli / cky"; in the half column the two constant
            // words drop out and only `talk ❯ ready` remains.
            HStack(spacing: 6) {
                if state.size != .half {
                    Text("peeky")
                        .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.98))
                    Text("on")
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(promptTabName)
                    .foregroundStyle(Color(red: 0.72, green: 0.50, blue: 0.98))
                Text("❯")
                    .foregroundStyle(state.accent)
                    .shadow(color: state.accent.opacity(0.8), radius: 4)
                Text(state.phase.label.lowercased())
                    .foregroundStyle(state.accent.opacity(0.9))
            }
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            .animation(.easeInOut(duration: 0.25), value: state.phase)
            if state.size != .half {
                Text("⌥⌘C ask · ⌥⌘V dictate")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.leading, 6)
            }
            Spacer()
            if state.size != .half {
            VStack(alignment: .trailing, spacing: 1) {
                Text("PEEKY")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .kerning(2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("Talk to any screen without leaving this one.")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
                    .fixedSize()
            }
            }
            coachButton
            if state.tab == .ask {
                readAloudToggle
            }
            micIndicator
            // While recording (either tab) the mic itself is the stop
            // control, so the red Stop button (which would discard the
            // recording) is redundant.
            if state.status == .listening {
                EmptyView()
            } else if state.canStop {
                stopButton
            } else {
                sendButton
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.canStop)
    }

    /// Codex-style "+" at the foot of Capture + Dictate: a small menu whose
    /// one entry, "Files and folders", opens the macOS picker. Whatever is
    /// chosen lands in the capture preview exactly as a region grab would.
    /// A native NSMenu rather than SwiftUI's `Menu`, which renders empty in
    /// this non-activating panel.
    private var addMenu: some View {
        Button {
            showAddMenu()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(state.tab == .ask ? "Attach images for your question (or drop / paste them here)"
              : state.tab == .code ? "Pick a project folder or files (or drop them here)"
                                   : "Add a file or folder from this Mac to the preview")
    }

    private func showAddMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var actions: [MenuAction] = []
        if state.tab == .ask {
            let full = state.askAttachments.count >= AssistantState.maxAskAttachments
            let images = NSMenuItem(title: full ? "Images (10 of 10 attached)" : "Images…",
                                    action: #selector(MenuAction.fire), keyEquivalent: "")
            images.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
            images.isEnabled = !full
            let pick = MenuAction { state.onAttachToAsk?() }
            images.target = pick
            actions.append(pick)
            menu.addItem(images)
            let paste = NSMenuItem(title: "Paste image from clipboard", action: #selector(MenuAction.fire), keyEquivalent: "")
            paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            paste.isEnabled = !full && NSPasteboard.general.canReadObject(forClasses: [NSImage.self, NSURL.self], options: nil)
            let pasteAction = MenuAction { state.onPasteIntoAsk?() }
            paste.target = pasteAction
            actions.append(pasteAction)
            menu.addItem(paste)
        } else if state.tab == .code {
            let folder = NSMenuItem(title: state.codeProject == nil ? "Project folder or files…" : "Replace project…",
                                    action: #selector(MenuAction.fire), keyEquivalent: "")
            folder.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            let pick = MenuAction { state.onAttachCodeProject?() }
            folder.target = pick
            actions.append(pick)
            menu.addItem(folder)
            let images = NSMenuItem(title: "Images for the question…", action: #selector(MenuAction.fire), keyEquivalent: "")
            images.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
            images.isEnabled = state.codeImages.count < AssistantState.maxCodeImages
            let imagesAction = MenuAction { state.onAttachCodeImages?() }
            images.target = imagesAction
            actions.append(imagesAction)
            menu.addItem(images)
            if state.codeProject != nil {
                let reload = NSMenuItem(title: "Re-read from disk", action: #selector(MenuAction.fire), keyEquivalent: "")
                reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
                let reloadAction = MenuAction { state.onReloadCodeProject?() }
                reload.target = reloadAction
                actions.append(reloadAction)
                menu.addItem(reload)
            }
        } else {
            let files = NSMenuItem(title: "Files and folders", action: #selector(MenuAction.fire), keyEquivalent: "")
            files.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
            let action = MenuAction { state.onAttachFile?() }
            files.target = action
            actions.append(action)
            menu.addItem(files)
        }
        // popUp blocks until dismissed, so the local targets stay alive.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = actions
    }

    // MARK: Ask history

    /// Clock at the head of the Ask line: flips between the current Q&A and
    /// the list of everything asked before. Lit while the list is up.
    private var historyButton: some View {
        let on = state.showingAskHistory
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.showingAskHistory.toggle() }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : .white.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? Color.white.opacity(0.9) : Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Back to the current question" : "History — every question you've asked, with its answer")
    }

    private var filteredHistory: [AskHistoryEntry] {
        let needle = state.historySearch.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return state.askHistory }
        return state.askHistory.filter {
            $0.question.localizedCaseInsensitiveContains(needle) || $0.answer.localizedCaseInsensitiveContains(needle)
        }
    }

    private var askHistoryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("History")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("\(state.askHistory.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("search", text: $state.historySearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 150)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                if !state.askHistory.isEmpty {
                    Button { state.onClearHistory?() } label: {
                        Text("clear all")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Delete every saved question")
                }
            }
            if state.askHistory.isEmpty {
                Text("Nothing yet — every question you ask shows up here with its answer, even after Peeky is closed.")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 4)
            } else if filteredHistory.isEmpty {
                Text("No questions match “\(state.historySearch)”.")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                        ForEach(historySections, id: \.label) { section in
                            Text(section.label.uppercased())
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .kerning(1.2)
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 10).padding(.bottom, 2).padding(.leading, 4)
                            ForEach(section.entries) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.top, 6)
    }

    private struct HistorySection { let label: String; let entries: [AskHistoryEntry] }

    private var historySections: [HistorySection] {
        var sections: [HistorySection] = []
        for entry in filteredHistory {
            let label = AskHistoryStore.dayLabel(for: entry.date)
            if let last = sections.last, last.label == label {
                sections[sections.count - 1] = HistorySection(label: label, entries: last.entries + [entry])
            } else {
                sections.append(HistorySection(label: label, entries: [entry]))
            }
        }
        return sections
    }

    private func historyRow(_ entry: AskHistoryEntry) -> some View {
        HistoryRow(entry: entry,
                   open: { state.onRestoreHistory?(entry) },
                   delete: { state.onDeleteHistory?(entry) })
    }

    /// One saved question: the question as the title, when it was asked,
    /// the first line of the answer under it. Click opens it; the trash on
    /// the right (shown on hover) forgets it.
    private struct HistoryRow: View {
        let entry: AskHistoryEntry
        let open: () -> Void
        let delete: () -> Void
        @State private var hovering = false

        private static let time: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
        }()

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.attachmentNames.isEmpty ? "bubble.left" : "photo.on.rectangle.angled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.question)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(Self.time.string(from: entry.date))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(entry.answer.replacingOccurrences(of: "\n", with: " "))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                }
                Spacer(minLength: 0)
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Forget this question")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: open)
            .onHover { hovering = $0 }
        }
    }

    // MARK: Ask attachments strip

    /// Drops of image files (Finder) or raw image data (a browser picture).
    private func handleAskDrop(_ providers: [NSItemProvider]) -> Bool {
        let handled = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !handled.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in handled {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("peeky-drop-\(UUID().uuidString).png")
                    if (try? data.write(to: tmp)) != nil { lock.lock(); urls.append(tmp); lock.unlock() }
                }
            }
        }
        group.notify(queue: .main) { [state] in
            guard !urls.isEmpty else { return }
            if state.tab == .code { state.onDropIntoCode?(urls) } else { state.onDropIntoAsk?(urls) }
        }
        return true
    }

    /// A thin row of thumbnails under the prompt line — pictures the
    /// question is about. Each has an × to drop it; the chevron folds the
    /// row to a one-line count when it's in the way. Hidden while empty.
    @ViewBuilder
    private var askAttachmentsStrip: some View {
        if !state.askAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { state.askAttachmentsCollapsed.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .rotationEffect(.degrees(state.askAttachmentsCollapsed ? 0 : 90))
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(state.askAttachments.count) of \(AssistantState.maxAskAttachments) \(state.askAttachments.count == 1 ? "image" : "images") attached — Peeky sees these with every question")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(state.askAttachmentsCollapsed ? "Show the attached images" : "Hide the attached images")
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { state.askAttachments.removeAll() }
                    } label: {
                        Text("clear all")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Remove every attached image")
                }
                if !state.askAttachmentsCollapsed {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.askAttachments) { item in
                                askThumbnail(item)
                            }
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                    }
                    .frame(height: 74)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }

    private func askThumbnail(_ item: AssistantState.AskAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .help(item.name)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.askAttachments.removeAll { $0.id == item.id }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.85)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove \(item.name)")
        }
    }

    /// The break coach's countdown, and its on/off switch. Always visible so
    /// the next check-in is never a surprise.
    private var coachButton: some View {
        let on = state.coachEnabled
        let tint = Color(red: 0.35, green: 0.85, blue: 0.45)
        return Button {
            state.onToggleCoach?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .semibold))
                Text(on ? state.coachCountdown : "break coach off")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? tint : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? tint.opacity(0.14) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .help(on ? "Break coach is on — Peeky checks in after 25 minutes at the computer. Click to turn off."
                 : "Break coach is off. Click to turn on.")
    }

    /// Peeky's check-in, with the two honest answers to it.
    private func coachCard(_ message: String) -> some View {
        let tint = Color(red: 0.35, green: 0.85, blue: 0.45)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 15, weight: .bold))
                Text("BREAK TIME")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .kerning(1.5)
                Spacer()
                if state.isSpeaking {
                    Image(systemName: "waveform")
                        .symbolEffect(.pulse, isActive: true)
                }
            }
            .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 15.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                coachAction("Taking a break", icon: "checkmark", fill: tint, dark: true) {
                    state.onCoachBreak?()
                }
                coachAction("5 more minutes", icon: "clock", fill: Color.white.opacity(0.12), dark: false) {
                    state.onCoachSnooze?()
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func coachAction(_ title: String, icon: String, fill: Color, dark: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .heavy))
                Text(title).font(.system(size: 13.5, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(dark ? .black.opacity(0.85) : .white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(
                Circle().fill(
                    typedQuestion.isEmpty
                        ? AnyShapeStyle(Color.white.opacity(0.14))
                        : AnyShapeStyle(LinearGradient(
                            colors: [.cyan, Color(red: 0.2, green: 0.55, blue: 0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                )
                )
        }
        .buttonStyle(.plain)
        .disabled(typedQuestion.isEmpty)
        .help("Send")
    }

    /// Red stop button shown while Peeky is thinking or speaking.
    private var stopButton: some View {
        Button {
            state.onStop?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .heavy))
                Text("Stop")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.35, blue: 0.35), Color(red: 0.85, green: 0.15, blue: 0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                )
            )
            .shadow(color: .red.opacity(0.45), radius: 6)
        }
        .buttonStyle(.plain)
        .help("Stop answering (Esc)")
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Drag-to-resize grip in one corner of the panel. Diagonal-arrow icon
    /// rotates to hug whichever diagonal it sits on.
    private func resizeHandle(_ corner: PanelResizeCorner) -> some View {
        let hovering = resizeHoverCorner == corner
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(hovering ? 0.6 : 0))
            .rotationEffect(.degrees(corner == .topTrailing || corner == .bottomLeading ? 90 : 0))
            .padding(9)
            .contentShape(Rectangle())
            .onHover { hovering in resizeHoverCorner = hovering ? corner : nil }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in state.onResize?(corner, value.translation) }
                    .onEnded { _ in state.onResize?(corner, nil) }
            )
            .help("Drag to resize")
    }

    /// Grab strip along the bottom edge: drag it up to shrink the panel (or
    /// down to grow it) without touching the width. A short pill lights up
    /// on hover so the edge reads as draggable.
    private var bottomEdgeHandle: some View {
        let hovering = resizeHoverCorner == .bottom
        return Capsule()
            .fill(.white.opacity(hovering ? 0.55 : 0.18))
            .frame(width: 44, height: 4)
            .padding(.vertical, 5)
            .padding(.horizontal, 40)
            .contentShape(Rectangle())
            .onHover { hovering in resizeHoverCorner = hovering ? .bottom : nil }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in state.onResize?(.bottom, value.translation) }
                    .onEnded { _ in state.onResize?(.bottom, nil) }
            )
            .help("Drag up to shrink, down to grow")
    }

    @ViewBuilder
    private var transcriptView: some View {
        if !state.transcript.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state.accent.opacity(0.8))
                    .padding(.top, 3)
                Text(state.transcript)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder
    private var answerView: some View {
        if let error = state.errorText {
            ScrollView {
                Text(error)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !state.answer.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if state.status == .answering {
                    HStack {
                        Spacer()
                        replayButton
                    }
                }
                // "Read Response" on means the user reads the text — Peeky
                // stays silent. Off means Peeky speaks it, so showing the
                // text too would defeat the point of the toggle. Talk is
                // always text: its answer is a running log of what Peeky is
                // doing, which is never spoken.
                if state.textOnlyMode || state.tab == .talk || state.restoredFromHistory {
                    // With a copied passage underneath, the answer (often just
                    // "Done.") hugs its own height so the passage — the thing
                    // worth reading — gets the room instead of a blank gap.
                    let hasCopied = !(state.copiedPreview ?? "").isEmpty
                    ScrollView {
                        Text(state.answer)
                            .font(.system(size: 15.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: hasCopied)
                    .frame(maxHeight: hasCopied ? 96 : .infinity)
                } else {
                    speakingPlaceholder
                }
                copiedPreviewView
            }
        } else {
            copiedPreviewView
        }
    }

    /// The passage a voice copy just put on the clipboard, shown so it can be
    /// checked by eye before it's sent anywhere.
    @ViewBuilder
    private var copiedPreviewView: some View {
        if let copied = state.copiedPreview, !copied.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("COPIED — on your clipboard")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                ScrollView([.vertical, .horizontal]) {
                    Text(copied)
                        .font(.system(size: 13.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                )
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 4)
        }
    }

    private var speakingPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isSpeaking ? "waveform" : "speaker.wave.2.fill")
                .symbolEffect(.pulse, isActive: state.isSpeaking)
            Text(state.isSpeaking ? "Reading the response aloud…" : "Response read aloud.")
        }
        .font(.system(size: 14.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lets the user hear the current answer again — the only way to hear it
    /// at all when "Read Response" (text-only mode) is switched on.
    private var replayButton: some View {
        Button {
            state.onReadAloud?()
        } label: {
            Label(state.isSpeaking ? "Reading…" : "Read aloud", systemImage: state.isSpeaking ? "waveform" : "speaker.wave.2")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan)
        .help("Read this answer aloud")
    }

    private func submit() {
        let text = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedQuestion = ""
        switch state.tab {
        case .talk: state.onDo?(text)
        case .code: state.onAskCode?(text)
        default: state.onSubmit?(text)
        }
    }

    /// Short tab name for the prompt line, the way a shell shows a branch.
    private var promptTabName: String {
        switch state.tab {
        case .captureDictate: "capture"
        case .ask: "ask"
        case .talk: "talk"
        case .code: "code"
        }
    }
}

/// Five bars that dance while speech is coming in. There is no audio level
/// to draw — the phone keeps the microphone — so the motion is synthetic,
/// but it only ever runs while partial transcripts are arriving, which is the
/// truth the user needs: words are being heard *right now*.
/// The one signal that never lies about the microphone: a pulsing red dot,
/// "REC", and how long it has been open. Shown in every form of the panel
/// whenever `micLive` is true, regardless of the phase colour — the phase
/// says what Peeky is doing, this says the mic is still hot.
private struct RecBadge: View {
    let since: Date?
    @State private var pulsing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .shadow(color: .red.opacity(pulsing ? 0.9 : 0.3), radius: pulsing ? 6 : 2)
                    .opacity(pulsing ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
                Text("REC")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .kerning(1.2)
                Text(Self.elapsed(since: since, now: context.date))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .opacity(0.85)
            }
            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.red.opacity(0.16))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.7), lineWidth: 1))
            )
        }
        .onAppear { pulsing = true }
        .onDisappear { pulsing = false }
        .help("The microphone is still recording. Press STOP or the mic to end it.")
        .accessibilityLabel("Recording")
    }

    static func elapsed(since: Date?, now: Date) -> String {
        guard let since else { return "0:00" }
        let total = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Red halo around the corner dot while the mic is hot, so a minimized
/// Peeky still shows it is recording.
private struct RecRing: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .strokeBorder(Color.red.opacity(pulsing ? 0.95 : 0.35), lineWidth: 2.5)
            .shadow(color: .red.opacity(pulsing ? 0.8 : 0.2), radius: pulsing ? 8 : 2)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
            .allowsHitTesting(false)
    }
}

private struct RecordingBars: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: animating ? Self.tall[index] : Self.short[index])
                    .animation(
                        .easeInOut(duration: Self.speed[index]).repeatForever(autoreverses: true),
                        value: animating
                    )
            }
        }
        .frame(height: 20)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }

    private static let tall: [CGFloat] = [12, 20, 16, 20, 10]
    private static let short: [CGFloat] = [4, 8, 5, 6, 4]
    private static let speed: [Double] = [0.38, 0.30, 0.45, 0.34, 0.41]
}

/// Closure-backed target for one-off NSMenu items built from SwiftUI.
private final class MenuAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}
