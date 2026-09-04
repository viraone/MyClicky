import AppKit
import SwiftUI

enum AssistantStatus {
    case idle, listening, thinking, answering

    var dotColor: Color {
        switch self {
        case .idle: .cyan
        case .listening: .red
        case .thinking: .yellow
        case .answering: .green
        }
    }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .answering: "Answer"
        }
    }
}

enum AssistantTab: String, CaseIterable {
    /// Region captures and dictation share one tab; both land on the clipboard together.
    /// Listed first so it's the default, leftmost tab.
    case captureDictate = "Capture + Dictate"
    case ask = "Ask"
    /// Voice/typed commands Clicky *acts on* (e.g. "create a calendar event
    /// at 2pm"), same plan-and-do flow as the phone's TALK button.
    case talk = "Talk"

    var icon: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .captureDictate: "camera.on.rectangle"
        case .talk: "bolt.fill"
        }
    }
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

@MainActor
final class AssistantState: ObservableObject {
    @Published var status: AssistantStatus = .idle
    @Published var transcript = ""
    @Published var answer = ""
    @Published var errorText: String?
    @Published var collapsed = false
    @Published var tab: AssistantTab = .captureDictate
    /// Last dictation result (on the clipboard, paired with the capture if any).
    @Published var dictationText = ""
    /// Last region capture (saved to disk; on the clipboard, paired with the dictation if any).
    @Published var captureImage: NSImage?
    @Published var captureURL: URL?
    /// True while Clicky is reading an answer aloud.
    @Published var isSpeaking = false
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
    @Published var isTall = false
    /// True whenever a request is in flight or speech is playing — i.e. when
    /// the Stop button should be shown.
    var canStop: Bool { status == .thinking || status == .listening || isSpeaking }
    var onSubmit: ((String) -> Void)?
    /// Talk tab: a command for Clicky to carry out on the Mac.
    var onDo: ((String) -> Void)?
    var onStop: (() -> Void)?
    /// Re-copies the current capture + dictation pair to the clipboard.
    var onCopyAgain: (() -> Void)?
    /// Reads the current answer aloud on demand, regardless of `textOnlyMode`.
    var onReadAloud: (() -> Void)?
    /// Mic button: starts recording (a question on the Ask tab, a dictation
    /// on Capture + Dictate), or stops and finishes it if already recording.
    var onToggleRecording: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onRestore: (() -> Void)?
    /// Toggles `isTall` and resizes the actual window to match.
    var onToggleTall: (() -> Void)?
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
        // Respect wherever the user dragged the panel: only reposition when
        // it isn't already visible. A fresh open starts at bottom-center.
        if !(panel.isVisible && panel.frame.intersects(visible)) {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - Self.expandedSize.width / 2,
                y: visible.minY + 120
            ))
        }
        panel.orderFrontRegardless()
    }

    // Card is 960x220 by default (960x520 when stretched tall via the header
    // button); the window carries an extra margin so the outer glow isn't
    // clipped. The user can also freely drag any corner — see `resize(_:)`.
    static let glowMargin: CGFloat = 24
    private static let expandedSize = NSSize(width: 960 + glowMargin * 2, height: 220 + glowMargin * 2)
    private static let tallSize = NSSize(width: 960 + glowMargin * 2, height: 520 + glowMargin * 2)
    private static let collapsedSize = NSSize(width: 56, height: 56)
    private static let minPanelSize = NSSize(width: 640 + glowMargin * 2, height: 160 + glowMargin * 2)
    private static let maxPanelSize = NSSize(width: 1500, height: 1000)
    /// Full frame just before minimizing, so restoring puts it back exactly
    /// (including any manual corner-resize) rather than snapping to a preset.
    private var savedFrame: NSRect?
    private var resizeStartFrame: NSRect?

    func minimize() {
        guard let panel, !state.collapsed else { return }
        savedFrame = panel.frame
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

    /// Stretches the panel taller (or back to normal) in place, growing
    /// upward so the bottom edge — closest to wherever the user is
    /// working — doesn't shift. Keeps whatever width the user last set.
    func toggleTall() {
        guard let panel, !state.collapsed else { return }
        state.isTall.toggle()
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let height = state.isTall ? Self.tallSize.height : Self.expandedSize.height
        var origin = panel.frame.origin
        origin.y = min(origin.y, visible.maxY - height - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: panel.frame.width, height: height),
                        display: true, animate: true)
    }

    /// Live corner-drag resize. `translation` is the cumulative drag offset
    /// from where this drag started (SwiftUI, down-positive); `nil` means the
    /// drag just ended. The opposite corner stays anchored in place.
    func resize(_ corner: PanelResizeCorner, translation: CGSize?) {
        guard let panel, !state.collapsed else { return }
        guard let translation else {
            resizeStartFrame = nil
            // Keep the header button's icon honest after a manual drag.
            state.isTall = panel.frame.height > (Self.expandedSize.height + Self.tallSize.height) / 2
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
        state.onToggleTall = { [weak self] in self?.toggleTall() }
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
            } else {
                expandedPanel
            }
        }
        .onExitCommand { state.onDismiss?() }
    }

    private var collapsedDot: some View {
        Button(action: { state.onRestore?() }) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                Circle()
                    .fill(state.status.dotColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: state.status.dotColor.opacity(0.8), radius: 5)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                tabBar
                Spacer()
                headerButton(state.isTall ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                             help: state.isTall ? "Shrink back down" : "Expand for a longer answer") {
                    state.onToggleTall?()
                }
                headerButton("arrow.down.right.and.arrow.up.left", help: "Minimize to corner") {
                    state.onMinimize?()
                }
                headerButton("xmark", help: "Close") {
                    state.onDismiss?()
                }
            }
            switch state.tab {
            case .ask, .talk:
                topInputRow
                transcriptView
                answerView
            case .captureDictate:
                captureDictateTab
            }
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: state.isTall)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.13, blue: 0.15),
                                Color(red: 0.06, green: 0.06, blue: 0.08),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // Faint top sheen for a glassy feel.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [state.status.dotColor.opacity(0.10), .clear],
                            center: .top,
                            startRadius: 0,
                            endRadius: 260
                        )
                    )
            }
        )
        // Crisp thin gradient rim with a bright 1px highlight.
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            state.status.dotColor.opacity(0.85),
                            state.status.dotColor.opacity(0.35),
                            state.status.dotColor.opacity(0.85),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) { resizeHandle(.topLeading) }
        .overlay(alignment: .topTrailing) { resizeHandle(.topTrailing) }
        .overlay(alignment: .bottomLeading) { resizeHandle(.bottomLeading) }
        .overlay(alignment: .bottomTrailing) { resizeHandle(.bottomTrailing) }
        .compositingGroup()
        // Soft outer halo (Spotlight-style) drawn as a blurred rounded rect so
        // the corners stay round, plus a grounding drop shadow.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(state.status.dotColor.opacity(breathing ? 0.42 : 0.16))
                .blur(radius: breathing ? 16 : 10)
                .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathing)
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
        .animation(.easeInOut(duration: 0.5), value: state.status)
    }

    // Segmented tab strip along the top edge of the panel.
    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(AssistantTab.allCases, id: \.self) { tab in
                Button {
                    state.tab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(state.tab == tab ? .white : Color.white.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(state.tab == tab
                            ? Color.white.opacity(0.14)
                            : Color.white.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
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
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: true)
                Text(state.transcript.isEmpty
                     ? "Listening… speak now. Click the mic again when you're done."
                     : state.transcript)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(state.transcript.isEmpty ? .white.opacity(0.6) : .white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = state.errorText {
                // A fresh recording attempt just failed — say so instead of
                // silently falling back to whatever old text is on screen.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.dictationText.isEmpty {
                Image(systemName: "mic.badge.plus")
                    .foregroundStyle(.white.opacity(0.4))
                Text("Click the mic (or hold ⌥⌘V) and speak — your words appear here and go on the clipboard with the image.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: state.status == .thinking ? "sparkles" : "checkmark.circle.fill")
                    .foregroundStyle(state.status == .thinking ? .yellow : .green)
                ScrollView {
                    Text(state.dictationText)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 40)
                Button {
                    state.dictationText = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                Button {
                    state.onCopyAgain?()
                } label: {
                    Label("Copy again", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                    if state.transcript.isEmpty {
                        Text("Listening… speak now. Click the mic again (or release ⌥⌘V) when done.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        ScrollView {
                            Text(state.transcript)
                                .font(.system(size: 15, design: .rounded))
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
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.dictationText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Click the mic below, or hold ⌥⌘V (or tap DICTATE on your phone) and speak.\nYour words are tidied up and copied to the clipboard.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(state.dictationText)
                        .font(.system(size: 14, design: .rounded))
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
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.dictationText = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    Button {
                        state.onCopyAgain?()
                    } label: {
                        Label("Copy again", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                    .overlay(alignment: .topTrailing) {
                        // Dismisses the preview only — the file already
                        // saved to disk (VIRADETH_RESUME) is untouched.
                        Button {
                            state.captureImage = nil
                            state.captureURL = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
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
                    Text("\(state.captureURL?.lastPathComponent ?? "Saved") — on your clipboard, click to open")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Press ⌃⌥X (or tap CAPTURE on your phone) and drag out a region.\nThe capture is saved, copied, and previewed here.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Claude-style: big input field on top, mic status at top-right.
    private var topInputRow: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if typedQuestion.isEmpty {
                    Text(state.tab == .talk ? "Tell Clicky what to do…" : "Ask Clicky anything…")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
                TextField("", text: $typedQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(submit)
            }
        }
        .padding(.top, 4)
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
            Image(systemName: listening ? "waveform" : "mic")
                .font(.system(size: listening ? 17 : 13, weight: .medium))
                .foregroundStyle(listening ? .red : state.status.dotColor.opacity(0.85))
                .symbolEffect(.pulse, isActive: listening)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(listening ? Color.red.opacity(0.2) : Color.white.opacity(0.08))
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
                    .font(.system(size: 10, weight: .semibold))
                Text("Read Response")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(state.textOnlyMode ? state.status.dotColor.opacity(0.9) : .white.opacity(0.4))
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
            ZStack {
                Circle()
                    .fill(state.status.dotColor.opacity(0.22))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(state.status.dotColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: state.status.dotColor.opacity(0.9), radius: 4)
            }
            .animation(.easeInOut(duration: 0.25), value: state.status)
            Text(state.status.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text("⌥⌘C ask · ⌥⌘V dictate")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.28))
                .padding(.leading, 6)
            Spacer()
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

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .heavy))
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
                .font(.system(size: 10, weight: .heavy))
                Text("Stop")
                .font(.system(size: 11, weight: .bold, design: .rounded))
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
                .font(.system(size: 9, weight: .bold))
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
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(hovering ? 0.6 : 0.2))
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(state.status.dotColor.opacity(0.8))
                    .padding(.top, 3)
                Text(state.transcript)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
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
                    .font(.system(size: 12, design: .rounded))
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
                    ScrollView {
                        Text(state.answer)
                            .font(.system(size: 13.5, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    speakingPlaceholder
                }
            }
        }
    }

    private var speakingPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isSpeaking ? "waveform" : "speaker.wave.2.fill")
                .symbolEffect(.pulse, isActive: state.isSpeaking)
            Text(state.isSpeaking ? "Reading the response aloud…" : "Response read aloud.")
        }
        .font(.system(size: 12.5, weight: .medium, design: .rounded))
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
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan)
        .help("Read this answer aloud")
    }

    private func submit() {
        let text = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedQuestion = ""
        if state.tab == .talk {
            state.onDo?(text)
        } else {
            state.onSubmit?(text)
        }
    }
}
