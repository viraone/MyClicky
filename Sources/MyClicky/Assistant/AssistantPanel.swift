import AppKit
import SwiftUI

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
        case .working: "Clicky is on it"
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
/// width at its full height — for parking Clicky down one side of the
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
    /// Region captures and dictation share one tab; both land on the clipboard together.
    /// Listed first so it's the default, leftmost tab.
    case captureDictate = "Capture + Dictate"
    case ask = "Ask / Question Only"
    /// Voice/typed commands Clicky *acts on* (e.g. "create a calendar event
    /// at 2pm"), same plan-and-do flow as the phone's TALK button.
    case talk = "Talk / Request"

    var icon: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .captureDictate: "camera.on.rectangle"
        case .talk: "bolt.fill"
        }
    }

    /// One-word name for the half-width column's tab bar.
    var shortName: String {
        switch self {
        case .ask: "Ask"
        case .captureDictate: "Capture"
        case .talk: "Talk"
        }
    }
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

/// Which corner of the panel is being dragged to resize it.
enum PanelResizeCorner: Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// The opposite corner, which stays put while this one moves.
    func anchor(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.maxX, y: rect.minY)
        case .topTrailing: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeading: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomTrailing: NSPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// This corner's own point.
    func point(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.minX, y: rect.maxY)
        case .topTrailing: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeading: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomTrailing: NSPoint(x: rect.maxX, y: rect.minY)
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
    /// Talk tab log: every command spoken and every line Clicky reported
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
    /// True while Clicky is reading an answer aloud.
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
    /// (⌥⌘C questions land here too). Off by default — Clicky reads replies
    /// aloud unless the user turns "Read Response" on to read them itself.
    /// Persisted so the choice sticks between launches.
    @Published var textOnlyMode: Bool = UserDefaults.standard.object(forKey: AssistantState.textOnlyModeKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(textOnlyMode, forKey: AssistantState.textOnlyModeKey) }
    }
    private static let textOnlyModeKey = "assistantTextOnlyMode"
    /// True while the panel is stretched taller to give a long answer more
    /// room, instead of leaving it all in a small scrolling area.
    @Published var size: PanelSize = .normal
    /// Kept for call sites that only care whether there's room for a long
    /// answer.
    var isTall: Bool { size == .tall }
    /// True whenever a request is in flight or speech is playing — i.e. when
    /// the Stop button should be shown.
    var canStop: Bool { status == .thinking || status == .listening || isSpeaking }
    var onSubmit: ((String) -> Void)?
    /// Talk tab: a command for Clicky to carry out on the Mac.
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
        // Flip the y sign: SwiftUI's translation is down-positive, AppKit's
        // window coordinates are up-positive.
        let dragged = NSPoint(x: original.x + translation.width, y: original.y - translation.height)

        let width = min(max(abs(dragged.x - anchor.x), Self.minPanelSize.width), Self.maxPanelSize.width)
        let height = min(max(abs(dragged.y - anchor.y), Self.minPanelSize.height), Self.maxPanelSize.height)
        let x = dragged.x >= anchor.x ? anchor.x : anchor.x - width
        let y = dragged.y >= anchor.y ? anchor.y : anchor.y - height

        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let clampedX = min(max(x, visible.minX), visible.maxX - width)
        let clampedY = min(max(y, visible.minY), visible.maxY - height)

        panel.setFrame(NSRect(x: clampedX, y: clampedY, width: width, height: height), display: true)
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
        self.panel = panel
        return panel
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
            switch state.tab {
            case .ask:
                topInputRow
                transcriptView
                answerView
            case .talk:
                topInputRow
                if state.status == .listening { transcriptView }
                talkLogView
            case .captureDictate:
                captureDictateTab
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
            ForEach(AssistantTab.allCases, id: \.self) { tab in
                Button {
                    state.tab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                        // The half column can't fit three full labels;
                        // show only the selected tab's name there.
                        if state.size != .half || state.tab == tab {
                            Text(state.size == .half ? tab.shortName : tab.rawValue)
                                .font(.system(size: 14, weight: state.tab == tab ? .semibold : .regular, design: .monospaced))
                        }
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
            Spacer()
        }
    }

    /// The one line that tells the user where they are in the voice flow —
    /// and, above all, when they may speak a command. Red with moving bars
    /// while words are coming in; amber the moment they stop; purple while
    /// Clicky works; green when it's finished. The whole panel shifts hue
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
                Text("Commands and what Clicky did with them show up here, timestamped. ⌘K clears.")
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
        default: "Ask Clicky anything…"
        }
    }

    /// Mic in the bottom bar: click to start recording, click again to stop.
    /// What it records follows the tab — a question on Ask, a dictation on
    /// Capture + Dictate, a command to carry out on Talk. (⌥⌘C / ⌥⌘V still
    /// work as system-wide shortcuts.)
    private var micIndicator: some View {
        let listening = state.status == .listening
        let idleHelp: String = switch state.tab {
        case .ask: "Ask by voice"
        case .talk: "Say what you want Clicky to do"
        case .captureDictate: "Start dictation"
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
    /// user reads replies as text (on) or Clicky speaks them aloud (off, the
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
              ? "Text only — click to have Clicky read replies aloud instead"
              : "Reading replies aloud — click to read them as text instead")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if state.tab == .captureDictate {
                addMenu
            }
            // Shell-prompt readout: `clicky on talk ❯` — the segments coloured
            // as a prompt colours them, the chevron in the phase colour.
            HStack(spacing: 6) {
                Text("clicky")
                    .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.98))
                Text("on")
                    .foregroundStyle(.white.opacity(0.6))
                Text(promptTabName)
                    .foregroundStyle(Color(red: 0.72, green: 0.50, blue: 0.98))
                Text("❯")
                    .foregroundStyle(state.accent)
                    .shadow(color: state.accent.opacity(0.8), radius: 4)
                Text(state.phase.label.lowercased())
                    .foregroundStyle(state.accent.opacity(0.9))
            }
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
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
                Text("CLICKY")
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
        .help("Add a file or folder from this Mac to the preview")
    }

    private func showAddMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let files = NSMenuItem(title: "Files and folders", action: #selector(MenuAction.fire), keyEquivalent: "")
        files.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        let action = MenuAction { state.onAttachFile?() }
        files.target = action
        menu.addItem(files)
        // popUp blocks until dismissed, so the local target stays alive.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        _ = action
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
        .help(on ? "Break coach is on — Clicky checks in after 25 minutes at the computer. Click to turn off."
                 : "Break coach is off. Click to turn on.")
    }

    /// Clicky's check-in, with the two honest answers to it.
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

    /// Red stop button shown while Clicky is thinking or speaking.
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
                // "Read Response" on means the user reads the text — Clicky
                // stays silent. Off means Clicky speaks it, so showing the
                // text too would defeat the point of the toggle. Talk is
                // always text: its answer is a running log of what Clicky is
                // doing, which is never spoken.
                if state.textOnlyMode || state.tab == .talk {
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
        default: state.onSubmit?(text)
        }
    }

    /// Short tab name for the prompt line, the way a shell shows a branch.
    private var promptTabName: String {
        switch state.tab {
        case .captureDictate: "capture"
        case .ask: "ask"
        case .talk: "talk"
        }
    }
}

/// Five bars that dance while speech is coming in. There is no audio level
/// to draw — the phone keeps the microphone — so the motion is synthetic,
/// but it only ever runs while partial transcripts are arriving, which is the
/// truth the user needs: words are being heard *right now*.
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
