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

/// The four card shapes. `half` is a narrow column — half the tall card's
/// width at its full height — for parking Peeky down one side of the
/// screen next to what's being worked on. Tabs go icon-only to fit. `full`
/// is the normal width run the whole height of the screen, for reading
/// code and a long answer at once.
enum PanelSize: Int, CaseIterable, Comparable {
    case half, normal, tall, full
    static func < (a: PanelSize, b: PanelSize) -> Bool { a.rawValue < b.rawValue }
    var symbol: String {
        switch self {
        case .half: return "rectangle.lefthalf.inset.filled"
        case .normal: return "rectangle.inset.filled"
        case .tall: return "rectangle.portrait.inset.filled"
        case .full: return "arrow.up.left.and.arrow.down.right.square"
        }
    }
    var label: String {
        switch self {
        case .half: return "Half width — a tall column down one side"
        case .normal: return "Normal"
        case .tall: return "Tall — room for a long answer"
        case .full: return "Full screen — edge to edge"
        }
    }
}

enum AssistantTab: String, CaseIterable {
    /// Listed first so it's the leftmost tab: asking is what the panel is
    /// for most of the time.
    case ask = "Peeky Ask"
    /// Region captures and dictation share one tab; both land on the clipboard together.
    case captureDictate = "Peeky Capture"
    /// Voice/typed commands Peeky *acts on* (e.g. "create a calendar event
    /// at 2pm"), same plan-and-do flow as the phone's TALK button.
    case talk = "Peeky Actions"
    /// A dropped project folder Claude can answer questions about. The
    /// project text is prompt-cached, so follow-ups cost a fraction of the
    /// first question.
    case code = "Peeky Code"
    /// A real shell, started in the Peeky Code project's folder. Local
    /// only — never talks to Claude.
    case terminal = "Terminal"

    var icon: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .captureDictate: "camera.on.rectangle"
        case .talk: "bolt.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        }

    }

    /// Tabs with a mic: everything but the terminal.
    var takesVoice: Bool { self != .terminal }

    /// One-word name for the half-width column's tab bar.
    var shortName: String {
        switch self {
        case .ask: "Ask"
        case .captureDictate: "Capture"
        case .talk: "Talk"
        case .code: "Code"
        case .terminal: "Term"
        }
    }
}

enum CodeAIProvider: String, CaseIterable {
    case claude
    case ollama

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .ollama: return "Local"
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
    /// The whole left edge: drag it out to widen the panel, in to narrow
    /// it. Only the width changes; the right edge stays put.
    case leading

    var isEdge: Bool { self == .bottom || self == .leading }

    /// The opposite corner, which stays put while this one moves.
    func anchor(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.maxX, y: rect.minY)
        case .topTrailing: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeading, .leading: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomTrailing, .bottom: NSPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// This corner's own point.
    func point(in rect: NSRect) -> NSPoint {
        switch self {
        case .topLeading: NSPoint(x: rect.minX, y: rect.maxY)
        case .topTrailing: NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeading, .leading: NSPoint(x: rect.minX, y: rect.minY)
        case .bottomTrailing, .bottom: NSPoint(x: rect.maxX, y: rect.minY)
        }
    }
}

/// Which version of a screen capture — as originally grabbed, or after the
/// user edited it in an external app like Preview — rides on the clipboard.
enum CaptureClipboardChoice { case original, edited }

/// The ✕ on one thumbnail of the Original/Edited pair. A dedicated view
/// (rather than a plain button) so it can brighten on hover.
private struct CaptureVersionCloseButton: View {
    let which: CaptureClipboardChoice
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.75 : 0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(6)
        .help(which == .original
              ? "Drop the original — keep the edited version"
              : "Drop the edited version — back to the original")
        .onHover { hovering = $0 }
    }
}

/// One small thumbnail in the Capture tab's tray strip: the picture (its
/// edited version if there is one), a cyan ring when it's the one in the
/// big preview, and its own ✕ that appears on hover.
private struct CaptureTrayThumb: View {
    let item: AssistantState.CaptureTrayItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: item.edited ?? item.image)
            .resizable()
            .aspectRatio(contentMode: item.kind == .file ? .fit : .fill)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.cyan.opacity(0.85) : Color.white.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1))
            .opacity(isSelected || hovering ? 1 : 0.7)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .overlay(alignment: .topTrailing) {
                if hovering || isSelected {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove \(item.url.lastPathComponent) from the tray")
                }
            }
            .help(item.url.lastPathComponent)
            .onHover { hovering = $0 }
    }
}

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
    @Published var codeShowingFiles = false {
        didSet { if codeShowingFiles { codeViewerExpanded = false } }
    }
    /// Path of the file open in the preview, nil for the whole project.
    @Published var codeFocusedFile: String? {
        didSet {
            if codeFocusedFile != nil { codeShowingFiles = false }
            codeLSPHover = nil
            codeLSPDiagnosticPreview = nil
            // A freshly opened file is there to be read; the caret only
            // folds the one you're on.
            if codeFocusedFile != nil, codeFocusedFile != oldValue { codeViewerCollapsed = false; codeViewerExpanded = false; closeCodeFind() }
            codeDraft = codeFocusedFile.flatMap { codeCurrentText(of: $0) } ?? ""
            if let path = codeFocusedFile { onLSPFocusFile?(path, codeDraft) }
        }
    }
    /// Files Peeky has saved since the project was read, by path. The
    /// project snapshot (and so the cached block Claude sees) stays as
    /// loaded; these ride along with a question as a small addendum, which
    /// costs pennies where re-bundling would be a full-price cache write.
    @Published var codeEdits: [String: String] = [:]
    /// The focused file's text as it stands in the editor.
    @Published var codeDraft = "" {
        didSet {
            if let path = codeFocusedFile { onLSPDocumentChange?(path, codeDraft) }
            guard let path = codeFocusedFile, codeDraft != codeCurrentText(of: path) else {
                codeSaveTask?.cancel(); return
            }
            // Autosave a beat after typing stops.
            codeSaveTask?.cancel()
            codeSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.codeFocusedFile == path else { return }
                self.onSaveCodeFile?(path, self.codeDraft)
            }
        }
    }
    private var codeSaveTask: Task<Void, Never>?
    /// When the focused file was last written to disk, for the header.
    @Published var codeLastSaved: Date?
    static let defaultCodeFontSize: CGFloat = 12.5
    @Published var codeFontSize = defaultCodeFontSize
    @Published var codeLSPStatus: CodeLSPStatus = .inactive
    @Published var codeLSPDiagnostics: [String: [CodeLSPDiagnostic]] = [:]
    @Published var codeLSPHover: String?
    @Published var codeLSPDiagnosticPreview: String?
    @Published var codeLSPCaretOffset = 0

    func zoomCode(by steps: Int) {
        if steps == 0 {
            codeFontSize = Self.defaultCodeFontSize
        } else {
            codeFontSize = min(28, max(9, codeFontSize + CGFloat(steps)))
        }
    }

    /// Folders in the file list the user has folded shut. Reset on load.
    @Published var codeCollapsedFolders: Set<String> = []

    // MARK: Run in Simulator
    /// The Xcode project/workspace inside the loaded folder, if any — shows ▶ Run.
    var codeXcodeContainer: URL? { codeProject.flatMap { XcodeRunner.container(in: $0.root) } }
    @Published var codeRunPhase: XcodeRunner.Phase = .idle
    @Published var codeBuildErrors: [XcodeRunner.BuildError] = []
    /// Set by an error row; the editor scrolls there once the file is open.
    @Published var codeJumpToLine: Int?
    @Published var codeJumpLineCount = 1
    /// Text the bottom question box should adopt (an error row filled it in).
    @Published var codePrefillQuestion: String?
    var onRunCode: (() -> Void)?
    var onCancelRun: (() -> Void)?
    var codeRunning: Bool {
        switch codeRunPhase { case .building, .installing: return true; default: return false }
    }

    // MARK: Code find bar
    @Published var codeFindVisible = false
    @Published var codeFindQuery = "" { didSet { if codeFindQuery != oldValue { codeFindIndex = 0 } } }
    /// Which match is current, 0-based into `codeFindMatches`.
    @Published var codeFindIndex = 0
    /// Bumped to ask the find field to take keyboard focus.
    @Published var codeFindFocusRequest = 0

    /// Every place the query appears in the draft (case-insensitive).
    var codeFindMatches: [NSRange] {
        guard codeFindVisible, !codeFindQuery.isEmpty else { return [] }
        let text = codeDraft as NSString
        var out: [NSRange] = []
        var from = 0
        while from < text.length {
            let r = text.range(of: codeFindQuery, options: [.caseInsensitive], range: NSRange(location: from, length: text.length - from))
            if r.location == NSNotFound { break }
            out.append(r)
            from = r.location + max(r.length, 1)
        }
        return out
    }
    func codeFindStep(_ delta: Int) {
        let count = codeFindMatches.count
        guard count > 0 else { return }
        codeFindIndex = ((codeFindIndex + delta) % count + count) % count
    }
    func closeCodeFind() {
        codeFindVisible = false
        codeFindQuery = ""
    }

    // MARK: Terminal
    /// The shell behind the Terminal tab. Lives as long as the panel does,
    /// so switching tabs doesn't lose your session.
    let terminal = TerminalSession()
    var onRestartTerminal: (() -> Void)?

    /// The file as it currently is on disk (after any Peeky saves).
    func codeCurrentText(of path: String) -> String? {
        codeEdits[path] ?? codeProject?.file(at: path)?.text
    }
    var codeDraftDirty: Bool {
        guard let path = codeFocusedFile, let current = codeCurrentText(of: path) else { return false }
        return codeDraft != current
    }
    /// An answer's code block that's just quoting `path` as it is.
    func codeBlockIsAlreadyInFile(_ code: String, path: String) -> Bool {
        guard let text = codeLiveText(of: path) else { return false }
        return CodeBlockApplier.alreadyContains(code, in: text)
    }
    /// Current text of a file: the unsaved draft when it's the open one.
    func codeLiveText(of path: String) -> String? {
        path == codeFocusedFile ? codeDraft : codeCurrentText(of: path)
    }
    var codePaths: [String] { codeProject?.files.map(\.path) ?? [] }

    /// Where a code block from an answer belongs — free, from the bundle.
    func codeLocate(code: String, find: String?, tagged: String?) -> CodeBlockLocator.Location? {
        guard codeProject != nil else { return nil }
        return CodeBlockLocator.locate(code: code, find: find, tagged: tagged, focused: codeFocusedFile,
                                       paths: codePaths, text: { self.codeLiveText(of: $0) })
    }

    /// Opens the file and puts the caret on the line.
    func jump(to location: CodeBlockLocator.Location) {
        if codeFocusedFile != location.path { codeFocusedFile = location.path }
        codeShowingFiles = false
        if let line = location.line {
            codeJumpToLine = line
            codeJumpLineCount = max(1, location.lineCount)
        }
    }

    /// Prose with `identifiers` that exist in the project turned into links.
    func codeLinkedProse(_ prose: String) -> AttributedString {
        var out = AttributedString(prose)
        guard codeProject != nil else { return out }
        let ns = prose as NSString
        let regex = try! NSRegularExpression(pattern: "`([^`\\n]{3,80})`")
        for m in regex.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let loc: CodeBlockLocator.Location?
            if let path = CodeBlockLocator.resolve(name, in: codePaths), name.contains(".") {
                loc = CodeBlockLocator.Location(path: path, line: nil, lineCount: 0)
            } else {
                loc = CodeBlockLocator.locate(identifier: name, focused: codeFocusedFile, paths: codePaths, text: { self.codeLiveText(of: $0) })
            }
            guard let loc, let range = Range(m.range, in: prose),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].link = Self.jumpURL(for: loc)
            out[lower..<upper].underlineStyle = .single
            out[lower..<upper].foregroundColor = NSColor(AssistantPhase.working.color)
        }
        return out
    }

    static func jumpURL(for loc: CodeBlockLocator.Location) -> URL {
        var c = URLComponents()
        c.scheme = "peeky-code"; c.host = "jump"
        c.queryItems = [URLQueryItem(name: "path", value: loc.path), URLQueryItem(name: "line", value: loc.line.map(String.init))]
        return c.url!
    }
    static func jumpLocation(from url: URL) -> CodeBlockLocator.Location? {
        guard url.scheme == "peeky-code", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value else { return nil }
        let line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        return CodeBlockLocator.Location(path: path, line: line, lineCount: 1)
    }
    /// Edited files whose text differs from the snapshot Claude has cached.
    var codeChangedFiles: [(path: String, text: String)] {
        codeEdits.compactMap { path, text in
            guard let original = codeProject?.file(at: path)?.text, original != text else { return nil }
            return (path, text)
        }.sorted { $0.path < $1.path }
    }
    /// The file preview is folded down to its header row.
    @Published var codeViewerCollapsed = false {
        didSet { if codeViewerCollapsed { codeViewerExpanded = false } }
    }
    /// The file preview fills the tab (log hidden) instead of the usual split.
    @Published var codeViewerExpanded = false
    /// Pictures (screenshots, mockups, error dialogs) that ride along with
    /// every code question until removed. Listed by name only.
    @Published var codeImages: [AskAttachment] = []
    static let maxCodeImages = 5
    /// Only Claude sends images with code questions; the Local path is text-only.
    var codeAcceptsImages: Bool { codeAIProvider == .claude }
    /// Estimated dollars spent on code questions since install, from the
    /// token counts each answer reports. Persisted so it survives relaunch.
    @Published var codeSpentUSD: Double = UserDefaults.standard.double(forKey: codeSpentKey) {
        didSet { UserDefaults.standard.set(codeSpentUSD, forKey: Self.codeSpentKey) }
    }
    static let codeSpentKey = "peeky.code.spentUSD"
    /// Real month-to-date spend from the Admin API, nil without an admin key
    /// or before the first fetch. When present it replaces the estimate.
    @Published var codeLiveCost: AnthropicService.LiveCost?
    static let codeProviderKey = "peeky.code.provider"
    static let codeOllamaModelKey = "peeky.code.ollamaModel"
    /// Menu and pill names for local models. Tags people recognise get the
    /// name they use for them; anything else shows its Ollama tag, minus a
    /// bare ":latest", so a freshly pulled model is still readable.
    static func ollamaDisplayName(_ tag: String) -> String {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        let family = parts[0], variant = parts.count > 1 ? parts[1] : "latest"
        switch (family, variant) {
        case ("qwen3-coder", "30b"): return "Qwen3-Coder 30B"
        case ("qwen3-coder-next", _): return "Qwen3-Coder-Next 80B"
        case ("qwen3.6", "35b-a3b"): return "Qwen3.6 35B-A3B"
        case ("qwen3.6", "27b"): return "Qwen3.6 27B"
        case ("gpt-oss", "20b"): return "GPT-OSS 20B"
        case ("gpt-oss", "120b"): return "GPT-OSS 120B"
        default: return variant == "latest" ? family : tag
        }
    }
    @Published var codeAIProvider = CodeAIProvider(
        rawValue: UserDefaults.standard.string(forKey: codeProviderKey) ?? ""
    ) ?? .claude {
        didSet {
            UserDefaults.standard.set(codeAIProvider.rawValue, forKey: Self.codeProviderKey)
            if codeAIProvider == .ollama, !codeImages.isEmpty {
                let n = codeImages.count
                codeImages.removeAll()
                logCode(.status, "Removed \(n) attached image\(n == 1 ? "" : "s") — the local model is text-only. Switch to Claude to attach images.")
            }
            onCodeProviderChanged?(codeAIProvider)
        }
    }
    @Published var codeOllamaModel = UserDefaults.standard.string(forKey: codeOllamaModelKey)
        ?? "qwen3-coder:30b" {
        didSet {
            UserDefaults.standard.set(codeOllamaModel, forKey: Self.codeOllamaModelKey)
            if oldValue != codeOllamaModel { onCodeModelChanged?(oldValue, codeOllamaModel) }
        }
    }
    @Published var codeOllamaModels: [String] = []
    @Published var codeOllamaStatus: String?

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
    /// Everything added to the Capture tab that hasn't been ✕'d yet, oldest
    /// first. Exactly one is "current" — the one the big preview, the
    /// Original/Edited pair, the file watcher, and the clipboard all refer
    /// to (`captureImage` & friends). The rest wait in a strip of thumbnails
    /// beneath it; clicking one swaps it in. Each item remembers its own
    /// edited version and clipboard choice so switching back loses nothing.
    struct CaptureTrayItem: Identifiable, Equatable {
        let id = UUID()
        var image: NSImage
        let url: URL
        let kind: AttachmentKind
        var edited: NSImage?
        var choice: CaptureClipboardChoice = .edited
        static func == (a: CaptureTrayItem, b: CaptureTrayItem) -> Bool { a.id == b.id }
    }
    static let maxCaptureTray = 10
    @Published var captureTray: [CaptureTrayItem] = []
    @Published var captureTraySelection: UUID?
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
    /// Drops just one version (original or edited) from the pair, keeping
    /// the other and the file watcher running.
    var onDiscardCaptureVersion: ((CaptureClipboardChoice) -> Void)?
    /// Tray strip: make another added image the current one, or drop one
    /// (current or not) without touching the others.
    var onSelectCaptureItem: ((UUID) -> Void)?
    var onRemoveCaptureItem: ((UUID) -> Void)?
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
    var onPasteCodeImage: (() -> Void)?
    /// Write `text` to the project file at `path` (relative to the root).
    var onSaveCodeFile: ((String, String) -> Void)?
    var onLSPFocusFile: ((String, String) -> Void)?
    var onLSPDocumentChange: ((String, String) -> Void)?
    var onLSPHover: ((String, Int, String) -> Void)?
    var onLSPDefinition: ((String, Int, String) -> Void)?
    var onCodeProviderChanged: ((CodeAIProvider) -> Void)?
    /// (previous model, new model) — the previous one can be let go of.
    var onCodeModelChanged: ((_ from: String, _ to: String) -> Void)?
    var onRefreshOllamaModels: (() -> Void)?
    /// Put a code block from an answer into the focused file. `find` is the
    /// block that preceded it in the answer, if any — the code to replace.
    var onApplyCodeBlock: ((_ code: String, _ find: String?, _ path: String) -> Void)?
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
    /// Header ↻ and ⏻: quit and reopen the installed build (so a fresh
    /// `build-app.sh` takes effect without a terminal), or just quit — the
    /// app has no Dock icon or menu bar, so these are the only way out.
    var onRelaunch: (() -> Void)?
    var onQuit: (() -> Void)?
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
            size = savedFrame?.size ?? Self.frameSize(for: state.size, on: screen)
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
        let wasCollapsed = state.collapsed
        if wasCollapsed { state.collapsed = false }
        if !state.strip {
            // `minimize()` already saved the full card frame. Do not replace
            // it with the dot's 56×56 frame when moving dot → strip, or the
            // strip chevron will restore a tiny square instead of the card.
            if panel.isVisible && !wasCollapsed { savedFrame = panel.frame }
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
    private static func frameSize(for size: PanelSize, on screen: NSScreen?) -> NSSize {
        switch size {
        case .half: return halfSize
        case .normal: return expandedSize
        case .tall: return tallSize
        case .full:
            // The whole screen, edge to edge, never smaller than Tall.
            let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? tallSize
            return NSSize(width: max(tallSize.width, visible.width - 16), height: max(tallSize.height, visible.height - 16))
        }
    }
    private static let collapsedSize = NSSize(width: 56, height: 56)
    private static let stripSize = NSSize(width: 420 + glowMargin * 2, height: 52 + glowMargin * 2)
    private static let minPanelSize = NSSize(width: 480 + glowMargin * 2, height: 160 + glowMargin * 2)
    private static let maxPanelSize = NSSize(width: 2400, height: 1600)
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
        let wasFull = state.size == .full
        state.size = size
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let target = Self.frameSize(for: size, on: screen)
        let height = target.height
        // Width only changes when entering or leaving the half column or
        // the full screen; the other two keep whatever width the user
        // dragged out. The right edge stays put so a panel parked at the
        // screen edge stays there.
        let width = (size == .half || wasHalf || size == .full || wasFull) ? target.width : panel.frame.width
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
            } else if f.height > (Self.expandedSize.height + Self.tallSize.height) / 2 {
                let full = Self.frameSize(for: .full, on: panel.screen).height
                state.size = f.height > (Self.tallSize.height + full) / 2 ? .full : .tall
            } else {
                state.size = .normal
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
            if corner == .leading {
                if resizeGrabOffset == nil { resizeGrabOffset = mouse.x - original.x }
                dragged = NSPoint(x: mouse.x - (resizeGrabOffset ?? 0), y: original.y)
            } else {
                if resizeGrabOffset == nil { resizeGrabOffset = mouse.y - original.y }
                dragged = NSPoint(x: original.x, y: mouse.y - (resizeGrabOffset ?? 0))
            }
        } else {
            // Flip the y sign: SwiftUI's translation is down-positive,
            // AppKit's window coordinates are up-positive.
            dragged = NSPoint(x: original.x + translation.width, y: original.y - translation.height)
        }

        let width = min(max(abs(dragged.x - anchor.x), Self.minPanelSize.width), Self.maxPanelSize.width)
        let height = min(max(abs(dragged.y - anchor.y), Self.minPanelSize.height), Self.maxPanelSize.height)
        // The left edge always sits left of its (right) anchor, and the
        // bottom edge below its (top) anchor, even if the pointer overshoots.
        let x = corner == .leading || dragged.x < anchor.x ? anchor.x - width : anchor.x
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

    /// Quits and reopens whatever is installed at this app's path — the
    /// one-click version of `osascript -e 'quit app "MyClicky"'; open …`.
    /// A detached shell waits for this process to actually exit before
    /// calling `open`, otherwise `open` would just re-activate the old one.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open '\(path)'"]
        do {
            try task.run()
        } catch {
            NSLog("Relaunch failed to start helper: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
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
        state.onRelaunch = { Self.relaunch() }
        state.onQuit = { NSApp.terminate(nil) }
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
        panel.onPaste = { [weak self] in
            guard let self else { return false }
            if self.state.tab == .terminal {
                self.state.terminal.view.paste(self)
                return true
            }
            guard self.state.tab == .code else { return false }
            let board = NSPasteboard.general
            // Text on the clipboard means a normal paste into a field; only
            // a bare image (a Capture, a screenshot) becomes an attachment.
            guard board.string(forType: .string) == nil,
                  board.canReadObject(forClasses: [NSImage.self], options: nil) else { return false }
            self.state.onPasteCodeImage?()
            return true
        }
        panel.onFind = { [weak self] in
            guard let self, self.state.tab == .code, self.state.codeFocusedFile != nil else { return false }
            self.state.codeViewerCollapsed = false
            self.state.codeFindVisible = true
            self.state.codeFindFocusRequest += 1
            return true
        }
        panel.onClear = { [weak self] in
            guard let self, self.state.tab == .terminal else { return false }
            self.state.terminal.clearScreen()
            return true
        }
        panel.onToggleCodeExpand = { [weak self] in
            guard let self, self.state.tab == .code, self.state.codeFocusedFile != nil,
                  !self.state.codeViewerCollapsed else { return false }
            self.state.codeViewerExpanded.toggle()
            return true
        }
        panel.onCodeZoom = { [weak self] steps in
            guard let self, self.state.tab == .code, self.state.codeFocusedFile != nil,
                  !self.state.codeViewerCollapsed else { return false }
            self.state.zoomCode(by: steps)
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

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Return true to consume Esc (e.g. to stop an in-flight answer) instead of closing.
    var onCancel: (() -> Bool)?
    /// ⌘V anywhere in the panel. Return true for terminal paste or a Code
    /// image attachment; false lets the focused field paste text.
    var onPaste: (() -> Bool)?
    /// ⌘F anywhere in the panel. Return true when a find bar took it.
    var onFind: (() -> Bool)?
    /// ⌘K. Return true when a terminal took it as "clear".
    var onClear: (() -> Bool)?
    /// ⇧⌘↩ on the Code tab. Return true when the file preview took it as
    /// "expand/restore".
    var onToggleCodeExpand: (() -> Bool)?
    /// ⌘+/⌘-/⌘0 in the Code editor. Positive/negative values zoom; zero resets.
    var onCodeZoom: ((Int) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command], key == "v", onPaste?() == true {
            return true
        }
        if flags == [.command], key == "f", onFind?() == true {
            return true
        }
        if flags == [.command], key == "k", onClear?() == true {
            return true
        }
        if flags == [.command, .shift], key == "\r", onToggleCodeExpand?() == true {
            return true
        }
        let zoomFlags = flags == [.command] || flags == [.command, .shift]
        if zoomFlags, (key == "+" || key == "="), onCodeZoom?(1) == true {
            return true
        }
        if zoomFlags, key == "-", onCodeZoom?(-1) == true {
            return true
        }
        if flags == [.command], key == "0", onCodeZoom?(0) == true {
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        // Peeky is a non-activating panel with no menu bar of its own, so
        // the Edit-menu shortcuts never arrive on their own. Send the
        // standard actions to whatever text field has focus.
        let action: Selector? = switch (key, flags) {
        case ("v", [.command]): #selector(NSText.paste(_:))
        case ("c", [.command]): #selector(NSText.copy(_:))
        case ("x", [.command]): #selector(NSText.cut(_:))
        case ("a", [.command]): #selector(NSText.selectAll(_:))
        case ("z", [.command]): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        if let action, let responder = firstResponder, responder.responds(to: action) {
            return NSApp.sendAction(action, to: responder, from: self)
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        orderOut(nil)
    }
}

struct AssistantPanelView: View {
    @ObservedObject var state: AssistantState
    @State private var typedQuestion = ""
    /// What the hovered header button does, shown in the header itself —
    /// system tooltips never appear over a non-activating panel.
    @State private var headerHint: String?
    @State private var copiedAnswerID: UUID?
    @FocusState private var fieldFocused: Bool
    @FocusState private var findFocused: Bool
    @State private var breathing = false
    @State private var resizeHoverCorner: PanelResizeCorner?
    @State private var codeViewerExpandHovering = false
    @State private var captureCopyAgainHovering = false
    @State private var captureCopyAgainFlash = false

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
                .frame(width: 26, height: 48)
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

    /// Second tab on the right edge, under the strip chevron: tucks the
    /// whole panel into its corner dot (what Minimize in the header did).
    private var edgeMinimizeTab: some View {
        Button {
            state.onMinimize?()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(state.accent)
                .frame(width: 26, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.accent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(state.accent.opacity(0.6), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help("Minimize to corner")
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
                .onHover { inside in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if inside { headerHint = size.label } else if headerHint == size.label { headerHint = nil }
                    }
                }
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
                headerButton("arrow.clockwise", help: "Relaunch Peeky") {
                    state.onRelaunch?()
                }
                headerButton("power", help: "Quit Peeky") {
                    state.onQuit?()
                }
                headerButton("xmark", help: "Close") {
                    state.onDismiss?()
                }
            }
            // The hovered button's description floats just under the header
            // row as an overlay, so showing it never changes the header's
            // own size (a layout-affecting hint fed a constraints loop).
            .overlay(alignment: .topTrailing) {
                if let hint = headerHint {
                    Text(hint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                        .offset(y: 34)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(1)
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
                    if !state.codeImages.isEmpty { codeImagesRow }
                    codeProjectCard
                    if state.codeRunPhase != .idle || !state.codeBuildErrors.isEmpty { codeRunStrip }
                    let viewerExpanded = state.codeViewerExpanded && !state.codeViewerCollapsed && state.codeFocusedFile != nil
                    if state.codeShowingFiles, let project = state.codeProject {
                        codeFileList(project)
                    } else if let path = state.codeFocusedFile, let file = state.codeProject?.file(at: path) {
                        codeFileViewer(file)
                            .frame(maxHeight: viewerExpanded ? .infinity : nil)
                    }
                    // With a file or the list up and nothing asked yet, the
                    // empty log's hint would steal half the height. Expanded,
                    // the preview alone fills the tab and the log is hidden.
                    if !viewerExpanded, !state.codeLog.isEmpty || (!state.codeShowingFiles && state.codeFocusedFile == nil) {
                        codeLogView
                    }
                case .terminal:
                    terminalTab
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
        .overlay(alignment: .trailing) {
            VStack(spacing: 8) {
                edgeChevron(expanded: true)
                edgeMinimizeTab
            }
            .padding(.trailing, 3)
        }
        .overlay(alignment: .bottom) { bottomEdgeHandle }
        .overlay(alignment: .leading) { leadingEdgeHandle }
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
                                .lineLimit(1)
                                .fixedSize()
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
                            .overlay(alignment: .topTrailing) { captureVersionCloseButton(.original) }
                            capturePreviewThumbnail(
                                image: edited, title: "Edited", fileName: state.captureURL?.lastPathComponent,
                                isSelected: state.clipboardChoice == .edited,
                                help: "Reloaded from disk after your changes were saved in Preview. Click to reopen it.",
                                onOpen: { if let url = state.captureURL { NSWorkspace.shared.open(url) } },
                                onSelect: { selectClipboardChoice(.edited) }
                            )
                            .overlay(alignment: .topTrailing) { captureVersionCloseButton(.edited) }
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
                    // The Original/Edited pair gets a ✕ on each thumbnail
                    // instead (see captureVersionCloseButton) — a group-level
                    // one there would dismiss both at once.
                    if state.editedCaptureImage == nil {
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
                }
                if state.captureTray.count > 1 {
                    captureTrayStrip
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    captureCopyAgainButton
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

    /// Per-thumbnail ✕ for the Original/Edited pair, dropping just that one
    /// version. Broken out of `captureColumn` (rather than inlined) because
    /// this file's big view bodies otherwise hit "unable to type-check in
    /// reasonable time".
    private func captureVersionCloseButton(_ which: CaptureClipboardChoice) -> some View {
        CaptureVersionCloseButton(which: which) {
            withAnimation(.easeInOut(duration: 0.18)) {
                state.onDiscardCaptureVersion?(which)
            }
        }
    }

    /// Every image added to the tab, as a row of small thumbnails under the
    /// preview once there's more than one. The current one is ringed in
    /// cyan; clicking another swaps it into the preview (and onto the
    /// clipboard); each has its own ✕. Newest on the right.
    private var captureTrayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.captureTray) { item in
                    CaptureTrayThumb(
                        item: item,
                        isSelected: item.id == state.captureTraySelection,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.18)) { state.onSelectCaptureItem?(item.id) }
                        },
                        onRemove: {
                            withAnimation(.easeInOut(duration: 0.18)) { state.onRemoveCaptureItem?(item.id) }
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(height: 72)
    }

    /// Selects which version (original vs. edited) rides the clipboard, and
    /// re-copies immediately so the choice takes effect right away.
    private func selectClipboardChoice(_ choice: CaptureClipboardChoice) {
        state.clipboardChoice = choice
        state.onCopyAgain?()
    }

    /// Re-copies the selected tray item — macOS only holds one clipboard
    /// item, so a copy elsewhere bumps this one off. Flashes a checkmark
    /// instead of resizing anything for feedback (fixed frame, no `.help`:
    /// this panel's hint overlay lives in the header, out of reach here).
    private var captureCopyAgainButton: some View {
        Button {
            state.onCopyAgain?()
            captureCopyAgainFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { captureCopyAgainFlash = false }
        } label: {
            Image(systemName: captureCopyAgainFlash ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(captureCopyAgainHovering ? 1 : 0.6))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .onHover { captureCopyAgainHovering = $0 }
    }

    private var captureStatusText: String {
        let name = state.captureURL?.lastPathComponent ?? "Saved"
        let tray = state.captureTray
        var position = ""
        if tray.count > 1, let index = tray.firstIndex(where: { $0.id == state.captureTraySelection }) {
            position = " · \(index + 1) of \(tray.count)"
        }
        switch state.attachmentKind {
        case .image: return "\(name) — added from this Mac, on your clipboard, click to open\(position)"
        case .file: return "\(name) — added from this Mac, copied as a file, click to open\(position)"
        case .capture: break
        }
        guard state.editedCaptureImage != nil else {
            return "\(name) — on your clipboard, click to open\(position)"
        }
        let which = state.clipboardChoice == .edited ? "Edited version" : "Original"
        return "\(which) on your clipboard — click the Edited thumbnail to reopen in Preview\(position)"
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
                        if state.codeXcodeContainer != nil { codeRunButton }
                        codeCardButton("arrow.up.forward.app", help: "Open this file in your editor") {
                            NSWorkspace.shared.open(project.root.appendingPathComponent(path))
                        }
                        codeCardButton("xmark", help: "Close the file — back to the whole project") {
                            withAnimation(.easeInOut(duration: 0.18)) { state.codeFocusedFile = nil }
                        }
                    } else {
                        if state.codeXcodeContainer != nil { codeRunButton }
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
                    if let profile = project.profile {
                        Button {
                            state.codePrefillQuestion = Self.sdetReviewPrompt
                        } label: {
                            Label(profile.title, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Active project profile: \(profile.relativePath). Click to prepare an SDET Review.")
                    }
                    if !project.detectedStack.isEmpty {
                        Text(project.detectedStack.map(\.name).joined(separator: " · "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(project.detectedStack.map { "\($0.name): \($0.evidence)" }.joined(separator: "\n"))
                    }
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
                    if state.codeAIProvider == .ollama {
                        codeCostPill("Local · $0",
                                     help: "\(state.codeOllamaModel) runs through Ollama on this Mac. No per-message API charge.")
                    } else if let live = state.codeLiveCost {
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

    /// ▶ on the project card: build and launch in the Simulator. Turns
    /// into ■ while a build is running.
    private var codeRunButton: some View {
        Button {
            if state.codeRunning { state.onCancelRun?() } else { state.onRunCode?() }
        } label: {
            HStack(spacing: 5) {
                if state.codeRunning {
                    ProgressView().controlSize(.mini)
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                } else {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    Text("Run")
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(state.codeRunning ? .white.opacity(0.8) : AssistantPhase.done.color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill((state.codeRunning ? Color.white : AssistantPhase.done.color).opacity(0.12)))
            .overlay(Capsule().strokeBorder((state.codeRunning ? Color.white : AssistantPhase.done.color).opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(state.codeRunning ? "Stop the build" : "Build and run in the iOS Simulator (xcodebuild + simctl, on this Mac — free)")
    }

    /// One line of build status, and the compiler's problems as clickable rows.
    private var codeRunStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch state.codeRunPhase {
                case .idle:
                    EmptyView()
                case .building(let started):
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("Building… \(Int(ctx.date.timeIntervalSince(started))) s")
                    }
                    .foregroundStyle(.white.opacity(0.7))
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Built — installing on the Simulator…").foregroundStyle(.white.opacity(0.7))
                case .succeeded(let device, let seconds):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AssistantPhase.done.color)
                    Text("Build succeeded · launched on \(device) · \(seconds) s").foregroundStyle(AssistantPhase.done.color)
                case .failed(let errors, let seconds):
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Build failed · \(errors) error\(errors == 1 ? "" : "s") · \(seconds) s — click one to ask Peeky").foregroundStyle(.red.opacity(0.9))
                case .cancelled:
                    Image(systemName: "stop.circle").foregroundStyle(.white.opacity(0.5))
                    Text("Build stopped").foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if !state.codeRunning {
                    Button {
                        state.codeRunPhase = .idle
                        state.codeBuildErrors = []
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Hide")
                }
            }
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            if !state.codeBuildErrors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.codeBuildErrors.prefix(30)) { err in codeErrorRow(err) }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(codeCardBackground)
    }

    private func codeErrorRow(_ err: XcodeRunner.BuildError) -> some View {
        Button {
            guard !err.isWarning || true else { return }
            if !err.file.isEmpty, state.codeProject?.file(at: err.file) != nil {
                state.jump(to: CodeBlockLocator.Location(path: err.file, line: err.line, lineCount: 1))
            }
            let place = err.file.isEmpty ? "" : " at \((err.file as NSString).lastPathComponent):\(err.line)"
            state.codePrefillQuestion = "Build \(err.isWarning ? "warning" : "error")\(place): \(err.message). Fix it."
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: err.isWarning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(err.isWarning ? .orange : .red)
                if !err.file.isEmpty {
                    Text("\((err.file as NSString).lastPathComponent):\(err.line)")
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(err.message)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(err.file.isEmpty ? "Ask Peeky about this" : "Open \(err.file) at line \(err.line) and ask Peeky to fix it")
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
                    let collapsed = state.codeCollapsedFolders.contains(group.folder)
                    if !group.folder.isEmpty {
                        Button {
                            if collapsed { state.codeCollapsedFolders.remove(group.folder) }
                            else { state.codeCollapsedFolders.insert(group.folder) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                                    .frame(width: 10)
                                Image(systemName: collapsed ? "folder" : "folder.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Self.codeFolderColor)
                                Text(group.folder + "/")
                                    .foregroundStyle(Self.codeFolderColor.opacity(0.9))
                                Spacer(minLength: 0)
                                if collapsed {
                                    Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s")")
                                        .fontWeight(.regular)
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(collapsed ? "Show files" : "Hide files")
                    }
                    if !collapsed {
                        ForEach(group.files, id: \.path) { file in
                            codeFileRow(file, indented: !group.folder.isEmpty)
                        }
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
        let appearance = Self.codeFileAppearance(for: file.path)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.codeFocusedFile = file.path }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: appearance.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appearance.color)
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

    private static let codeFolderColor = Color(red: 0.86, green: 0.68, blue: 0.35)

    private static func codeFileAppearance(for path: String) -> (icon: String, color: Color) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch name {
        case "package.json":
            return ("curlybraces", Color(red: 0.45, green: 0.76, blue: 0.42))
        case "readme", "readme.md", "readme.markdown":
            return ("book.closed.fill", Color(red: 0.38, green: 0.72, blue: 0.94))
        case "dockerfile":
            return ("shippingbox.fill", Color(red: 0.25, green: 0.65, blue: 0.95))
        default:
            break
        }
        switch ext {
        case "swift": return ("swift", Color(red: 0.96, green: 0.43, blue: 0.24))
        case "js", "mjs", "cjs": return ("j.square.fill", Color(red: 0.94, green: 0.80, blue: 0.25))
        case "ts", "tsx": return ("t.square.fill", Color(red: 0.30, green: 0.64, blue: 0.91))
        case "jsx": return ("atom", Color(red: 0.38, green: 0.78, blue: 0.91))
        case "json": return ("curlybraces", Color(red: 0.86, green: 0.75, blue: 0.32))
        case "html", "htm": return ("chevron.left.forwardslash.chevron.right", Color(red: 0.93, green: 0.36, blue: 0.22))
        case "css", "scss", "sass", "less": return ("number.square.fill", Color(red: 0.40, green: 0.55, blue: 0.94))
        case "py": return ("chevron.left.forwardslash.chevron.right", Color(red: 0.38, green: 0.66, blue: 0.84))
        case "md", "markdown": return ("text.document.fill", Color(red: 0.38, green: 0.72, blue: 0.94))
        case "yaml", "yml": return ("list.bullet.rectangle", Color(red: 0.78, green: 0.40, blue: 0.48))
        case "sh", "bash", "zsh", "fish": return ("terminal.fill", Color(red: 0.43, green: 0.78, blue: 0.46))
        case "sql": return ("cylinder.fill", Color(red: 0.85, green: 0.55, blue: 0.85))
        default: return ("doc.text.fill", Color.white.opacity(0.55))
        }
    }

    /// One file, the way the capture preview shows one image — and
    /// editable: type, and a second later it's saved to disk, where VS Code
    /// or any other editor with the file open picks it up.
    private func codeFileViewer(_ file: CodeProject.File) -> some View {
        let lineCount = state.codeDraft.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let diagnostics = state.codeLSPDiagnostics[file.path] ?? []
        let diagnosticHighlights = diagnostics.compactMap { diagnostic in
            TypeScriptLSPClient.nsRange(diagnostic.range, in: state.codeDraft)
                .map { CodeEditorDiagnosticHighlight(range: $0, severity: diagnostic.severity) }
        }
        let lspColor: Color = {
            switch state.codeLSPStatus {
            case .ready: return AssistantPhase.done.color
            case .starting: return AssistantPhase.working.color
            case .failed: return .orange
            case .inactive: return .white.opacity(0.3)
            }
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
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
                        Text("\(lineCount) lines")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.codeViewerCollapsed ? "Show the file" : "Collapse the file preview")
                Spacer(minLength: 0)
                if state.codeDraftDirty {
                    Text("saving…")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.9))
                } else if let saved = state.codeLastSaved, state.codeEdits[file.path] != nil {
                    Text("saved \(Self.logClock.string(from: saved)) · VS Code sees it")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(AssistantPhase.done.color.opacity(0.9))
                } else {
                    Text("edit here — saves to disk")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                if !state.codeViewerCollapsed {
                    Button {
                        state.codeFindVisible = true
                        state.codeFindFocusRequest += 1
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(state.codeFindVisible ? AssistantPhase.working.color : .white.opacity(0.5))
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Find in this file (⌘F — click in the file first so Peeky has the keyboard)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            if TypeScriptLSPClient.supports(path: file.path) {
                HStack(spacing: 10) {
                    Image(systemName: state.codeLSPStatus == .ready
                          ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                        .foregroundStyle(lspColor)
                    Text(state.codeLSPStatus.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(lspColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !diagnostics.isEmpty {
                        Button {
                            let first = diagnostics[0]
                            state.codeJumpToLine = first.range.start.line + 1
                            state.codeJumpLineCount = max(1, first.range.end.line - first.range.start.line + 1)
                        } label: {
                            Label("\(diagnostics.count)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(diagnostics.contains(where: { $0.severity == 1 }) ? .red : .orange)
                        }
                        .buttonStyle(.plain)
                        .help(diagnostics.map(\.message).joined(separator: "\n"))
                        .onHover { hovering in
                            state.codeLSPDiagnosticPreview = hovering
                                ? diagnostics.enumerated().map { "\($0.offset + 1). \($0.element.message)" }
                                    .joined(separator: "\n")
                                : nil
                        }
                    }
                    if state.codeLSPStatus == .ready {
                        Button {
                            state.onLSPHover?(file.path, state.codeLSPCaretOffset, state.codeDraft)
                        } label: {
                            Label("Hover", systemImage: "info.bubble")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Show type information for the symbol at the caret")
                        Button {
                            state.onLSPDefinition?(file.path, state.codeLSPCaretOffset, state.codeDraft)
                        } label: {
                            Label("Definition", systemImage: "arrow.turn.down.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Go to definition")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.035))
                .help(state.codeLSPStatus.detail)
            }
            if !state.codeViewerCollapsed {
                if state.codeFindVisible { codeFindBar }
                if let message = state.codeLSPDiagnosticPreview ?? state.codeLSPHover, !message.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: state.codeLSPDiagnosticPreview == nil
                              ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.codeLSPDiagnosticPreview == nil
                                             ? AssistantPhase.working.color : .red)
                        Text(message)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(4)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            state.codeLSPHover = nil
                            state.codeLSPDiagnosticPreview = nil
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.04))
                }
                CodeTextEditor(text: $state.codeDraft,
                               highlights: state.codeFindMatches,
                               current: state.codeFindMatches.isEmpty ? nil : state.codeFindMatches[min(state.codeFindIndex, state.codeFindMatches.count - 1)],
                               onFind: { state.codeFindVisible = true; state.codeFindFocusRequest += 1 },
                               onEscape: { state.closeCodeFind() },
                               onSelectionChange: { state.codeLSPCaretOffset = $0; state.codeLSPHover = nil },
                               diagnostics: diagnosticHighlights,
                               language: SyntaxHighlighter.language(for: file.path),
                               jumpToLine: state.codeJumpToLine,
                               jumpLineCount: state.codeJumpLineCount,
                               onDidJump: { state.codeJumpToLine = nil },
                               font: .monospacedSystemFont(ofSize: state.codeFontSize, weight: .regular))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(codeCardBackground)
        .overlay(alignment: .bottom) {
            if !state.codeViewerCollapsed { codeViewerExpandToggle }
        }
        .id(file.path)
    }

    /// Slim pill on the bottom edge of the file preview: click to fill the
    /// tab with the code preview (the log hidden), click again to restore
    /// the usual split.
    private var codeViewerExpandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.codeViewerExpanded.toggle() }
        } label: {
            Image(systemName: state.codeViewerExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(state.accent)
                .frame(width: 44, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(state.accent.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(state.accent.opacity(0.6), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .opacity(codeViewerExpandHovering ? 1 : 0.55)
        .onHover { codeViewerExpandHovering = $0 }
        .offset(y: 8)
        .help(state.codeViewerExpanded ? "Restore the answer log" : "Expand the code preview")
    }

    /// Compact find bar for the file preview: a short field, `3 of 12`,
    /// ↑/↓ (or ↩/⇧↩) step through matches, Esc closes.
    private var codeFindBar: some View {
        let matches = state.codeFindMatches
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Find", text: $state.codeFindQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.white)
                .focused($findFocused)
                .frame(width: 220)
                .onKeyPress(.downArrow) { state.codeFindStep(1); return .handled }
                .onKeyPress(.upArrow) { state.codeFindStep(-1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    state.codeFindStep(press.modifiers.contains(.shift) ? -1 : 1); return .handled
                }
                .onKeyPress(.escape) { state.closeCodeFind(); return .handled }
            Text(state.codeFindQuery.isEmpty ? "" : matches.isEmpty ? "no matches" : "\(state.codeFindIndex + 1) of \(matches.count)")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(matches.isEmpty && !state.codeFindQuery.isEmpty ? .orange.opacity(0.9) : .white.opacity(0.5))
                .frame(minWidth: 70, alignment: .leading)
            Button { state.codeFindStep(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.count < 2)
                .help("Previous match (↑)")
            Button { state.codeFindStep(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.count < 2)
                .help("Next match (↓)")
            Spacer(minLength: 0)
            Button { state.closeCodeFind() } label: {
                Text("Done")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            }
            .help("Close find (Esc)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05))
        .onAppear { findFocused = true }
        .onChange(of: state.codeFindFocusRequest) { _ in findFocused = true }
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

    private static let sdetReviewPrompt = """
    Perform a mid-level SDET readiness review of this project using the active \
    project profile and only evidence present in the loaded files. Separate \
    what is implemented from what is missing or only planned. Assess test \
    architecture, Playwright practices, TypeScript quality, UI and API \
    coverage, test-data and SQL strategy, CI, Docker, linting/formatting, and \
    HTML/JUnit/Allure reporting. Cite exact file paths for every finding, rank \
    the gaps by hiring impact, and recommend the next three concrete changes. \
    Also explain how I should discuss the strongest existing design decisions \
    in a mid-level SDET interview. Do not invent files, tests, or integrations.
    """

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

    // MARK: Terminal tab

    private var terminalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(state.terminal.startedIn.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "shell")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(state.terminal.running ? "local shell · free — nothing here goes to Claude" : "shell exited")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Button {
                    state.onRestartTerminal?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(state.codeProject == nil ? "Restart the shell" : "Restart the shell in \(state.codeProject!.name)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            TerminalPane(session: state.terminal)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(codeCardBackground)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { state.onRestartTerminal?() }
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
                // Yours: purple tint with a purple rail.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("❯")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundStyle(AssistantPhase.working.color)
                    Text(entry.text)
                        .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(speakerCard(AssistantPhase.working.color, fill: 0.12))
            case .answer:
                // Peeky's: cool grey with the DONE-green rail.
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(AssistantPhase.done.color).frame(width: 6, height: 6)
                        Text("peeky")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(AssistantPhase.done.color.opacity(0.9))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    codeAnswerView(entry.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyAnswerButton(entry)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(speakerCard(AssistantPhase.done.color, fill: 0.06, tint: .white))
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

    /// Speech card: soft fill with a coloured rail down the left edge so
    /// you can tell who's talking at a glance.
    private func speakerCard(_ rail: Color, fill: Double, tint: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((tint ?? rail).opacity(fill))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(rail.opacity(0.85))
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 3)
            }
    }

    /// Copies the whole answer (prose and code, as Claude wrote it). Shows a
    /// ✓ for a moment so you know it landed.
    private func copyAnswerButton(_ entry: CodeLogEntry) -> some View {
        let copied = copiedAnswerID == entry.id
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copiedAnswerID = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedAnswerID == entry.id { copiedAnswerID = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                if copied { Text("Copied").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
            }
            .foregroundStyle(copied ? AssistantPhase.done.color : .white.opacity(0.45))
            .frame(height: 20)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy Peeky's whole answer")
    }

    /// An answer with its fenced code blocks pulled out into cards. Each
    /// card says where the code goes (file:line, worked out locally), with
    /// Copy, a jump to that spot, and Apply — which targets that file even
    /// when a different one is open. Backticked names in the prose that
    /// exist in the project are links to where they're defined.
    private func codeAnswerView(_ text: String) -> some View {
        CodeAnswerCards(state: state, text: text)
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
        case .terminal: "Type a command…"
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
        case .terminal: "Switch to a tab with a mic"
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
            if state.tab == .code {
                codeProviderMenu
            }
            if state.tab == .code || state.tab == .terminal {
                bottomInputField
            } else {
                promptReadout
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

    private var codeProviderMenu: some View {
        Menu {
            Button {
                state.codeAIProvider = .claude
            } label: {
                Label("Claude (cloud)", systemImage: state.codeAIProvider == .claude ? "checkmark" : "cloud")
            }
            Divider()
            Button {
                state.codeAIProvider = .ollama
                state.codeOllamaModel = "qwen3-coder:30b"
            } label: {
                Label("Qwen3-Coder 30B", systemImage:
                    state.codeAIProvider == .ollama && state.codeOllamaModel == "qwen3-coder:30b"
                        ? "checkmark" : "desktopcomputer")
            }
            ForEach(state.codeOllamaModels.filter { $0 != "qwen3-coder:30b" }, id: \.self) { model in
                Button {
                    state.codeAIProvider = .ollama
                    state.codeOllamaModel = model
                } label: {
                    Label(AssistantState.ollamaDisplayName(model), systemImage:
                        state.codeAIProvider == .ollama && state.codeOllamaModel == model
                            ? "checkmark" : "desktopcomputer")
                }
            }
            Divider()
            Button("Refresh local models") {
                state.onRefreshOllamaModels?()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.codeAIProvider == .ollama ? "desktopcomputer" : "cloud")
                    .foregroundStyle(.white)
                Text(codeProviderLabel)
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    state.codeAIProvider == .ollama
                        ? AssistantPhase.done.color.opacity(0.35)
                        : Color.white.opacity(0.15)
                )
            )
            .overlay {
                Capsule().stroke(
                    state.codeAIProvider == .ollama
                        ? AssistantPhase.done.color.opacity(0.75)
                        : Color.white.opacity(0.25),
                    lineWidth: 1
                )
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.codeAIProvider == .ollama
              ? "\(state.codeOllamaModel) on this Mac · no API charge"
                + (state.codeOllamaStatus.map { "\n\($0)" } ?? "")
              : "Claude cloud API")
        .onAppear {
            if state.codeAIProvider == .ollama { state.onRefreshOllamaModels?() }
        }
    }

    private var codeProviderLabel: String {
        guard state.codeAIProvider == .ollama else { return "Claude · Cloud" }
        return "Ollama · \(AssistantState.ollamaDisplayName(state.codeOllamaModel))"
    }

    /// The Code tab's question box, down by the send button where a chat
    /// box is expected. It grows with what's in it — paste forty lines of
    /// code and you see them (⌥↩ adds a line; ↩ sends).
    private var bottomInputField: some View {
        ZStack(alignment: .topLeading) {
            if typedQuestion.isEmpty {
                Text(inputPlaceholder)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .padding(.leading, 2)
            }
            TextField("", text: $typedQuestion, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onChange(of: state.codePrefillQuestion) { text in
                    guard let text else { return }
                    typedQuestion = text
                    fieldFocused = true
                    state.codePrefillQuestion = nil
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(submit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(fieldFocused ? 0.22 : 0.10), lineWidth: 1))
    }

    private var promptReadout: some View {
        Group {
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
        }
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
            let images = NSMenuItem(title: state.codeAcceptsImages ? "Images for the question…" : "Images for the question (Claude only)", action: #selector(MenuAction.fire), keyEquivalent: "")
            images.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
            images.isEnabled = state.codeAcceptsImages && state.codeImages.count < AssistantState.maxCodeImages
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
        let hovering = headerHint == help
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                if inside { headerHint = help } else if headerHint == help { headerHint = nil }
            }
        }
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

    /// Grab strip up the left edge: drag it out to widen the panel (or in
    /// to narrow it) while the right edge stays where it is. Mirrors the
    /// bottom grip — a short vertical pill lights up on hover.
    private var leadingEdgeHandle: some View {
        let hovering = resizeHoverCorner == .leading
        return Capsule()
            .fill(.white.opacity(hovering ? 0.55 : 0.18))
            .frame(width: 4, height: 44)
            .padding(.horizontal, 5)
            .padding(.vertical, 40)
            .contentShape(Rectangle())
            .onHover { hovering in
                resizeHoverCorner = hovering ? .leading : nil
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in state.onResize?(.leading, value.translation) }
                    .onEnded { _ in state.onResize?(.leading, nil) }
            )
            .help("Drag left to widen, right to narrow")
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
        case .terminal: state.terminal.view.send(txt: text + "\n")
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
        case .terminal: "terminal"
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
