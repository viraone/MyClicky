import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "MyClicky", category: "documentary")

/// The Peeky Code Doc tab: pick a code file, Claude writes a short
/// documentary script about it, and a local Manim + Kokoro pipeline turns
/// that into a narrated, animated MP4. Only the script-writing step talks to
/// Claude; narration and rendering happen on this Mac.
///
/// The pipeline lives outside the app (default `~/code-documentary`) so it
/// can be edited and run by hand too — see `make_doc.py` there.
@MainActor
final class CodeDocumentaryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case writingScript
        case narrating
        case rendering
        case done(URL)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .writingScript, .narrating, .rendering: true
            default: false
            }
        }
    }

    struct Voice: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let voices: [Voice] = [
        Voice(id: "am_michael", label: "Michael · warm narrator"),
        Voice(id: "am_adam", label: "Adam · deep"),
        Voice(id: "am_fenrir", label: "Fenrir · gravelly"),
        Voice(id: "af_heart", label: "Heart · female"),
        Voice(id: "af_bella", label: "Bella · female, bright"),
        Voice(id: "bm_george", label: "George · British"),
        Voice(id: "bf_emma", label: "Emma · British, female"),
    ]

    enum Quality: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: "Fast · 480p"
            case .medium: "Standard · 720p"
            case .high: "Best · 1080p"
            }
        }
    }

    struct Recent: Identifiable, Equatable {
        let id: URL
        let title: String
        let date: Date
        var url: URL { id }
    }

    @Published var sourceFile: URL?
    @Published var phase: Phase = .idle
    @Published var logLines: [String] = []
    @Published var scriptTitle: String?
    @Published var recent: [Recent] = []
    @Published var voice: String {
        didSet { UserDefaults.standard.set(voice, forKey: "documentaryVoice") }
    }
    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "documentaryQuality") }
    }

    private var process: Process?
    private var generation = 0

    init() {
        voice = UserDefaults.standard.string(forKey: "documentaryVoice") ?? "am_michael"
        quality = Quality(rawValue: UserDefaults.standard.string(forKey: "documentaryQuality") ?? "") ?? .high
        refreshRecent()
    }

    // MARK: Pipeline location

    /// Folder holding `make_doc.py` and its `.venv`. Override with
    /// `defaults write MyClicky documentaryPipelineDir /path`.
    static var pipelineDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "documentaryPipelineDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code-documentary")
    }

    static var pythonURL: URL { pipelineDir.appendingPathComponent(".venv/bin/python") }
    static var makeDocURL: URL { pipelineDir.appendingPathComponent("make_doc.py") }
    static var narrateURL: URL { pipelineDir.appendingPathComponent("narrate.py") }
    static var projectsDir: URL { pipelineDir.appendingPathComponent("projects") }

    var pipelineReady: Bool {
        FileManager.default.isExecutableFile(atPath: Self.pythonURL.path)
            && FileManager.default.fileExists(atPath: Self.makeDocURL.path)
    }

    // MARK: Choosing a file

    func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the code file to make a documentary about"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            setSource(url)
        }
    }

    /// Accepts a file URL or a typed path. Rejects folders and anything that
    /// isn't readable text.
    @discardableResult
    func setSource(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            phase = .failed("\(url.lastPathComponent) isn't a file.")
            return false
        }
        guard let data = FileManager.default.contents(atPath: url.path),
              String(data: data.prefix(64_000), encoding: .utf8) != nil else {
            phase = .failed("\(url.lastPathComponent) doesn't look like a text file.")
            return false
        }
        sourceFile = url
        if case .failed = phase { phase = .idle }
        return true
    }

    func setSource(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
        guard !trimmed.isEmpty else { return false }
        return setSource(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
    }

    // MARK: Running

    func generate() {
        guard !phase.isRunning else { return }
        guard let source = sourceFile else {
            phase = .failed("Choose a code file first.")
            return
        }
        guard pipelineReady else {
            phase = .failed("Pipeline not found at \(Self.pipelineDir.path). See the setup note below.")
            return
        }
        guard let apiKey = KeychainService.anthropicAPIKey(), !apiKey.isEmpty else {
            phase = .failed("No Anthropic API key in Keychain. Run once in Terminal:\n\(KeychainService.setupCommand)")
            return
        }

        generation += 1
        let gen = generation
        logLines = []
        scriptTitle = nil
        phase = .writingScript
        ActivityLog.recordAction("code-documentary", ["file": source.lastPathComponent])

        Task {
            do {
                let code = try String(contentsOf: source, encoding: .utf8)
                append("Reading \(source.lastPathComponent) (\(code.split(separator: "\n", omittingEmptySubsequences: false).count) lines)")
                append("Asking Claude for a documentary script…")
                let script = try await Self.writeScript(for: code, at: source, apiKey: apiKey)
                guard gen == generation else { return }
                scriptTitle = script["title"] as? String
                let sceneCount = (script["scenes"] as? [[String: Any]])?.count ?? 0
                append("Script ready: \"\(scriptTitle ?? "Untitled")\" · \(sceneCount) scenes")

                let project = try Self.makeProjectDir(for: source)
                let data = try JSONSerialization.data(withJSONObject: script, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: project.appendingPathComponent("script.json"))
                append("Project: \(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")

                phase = .narrating
                try await runPipeline(project: project, generation: gen)
            } catch is CancellationError {
                if gen == generation { phase = .idle }
            } catch {
                guard gen == generation else { return }
                log.error("documentary failed: \(error.localizedDescription)")
                append("✗ \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
        append("Cancelled")
        phase = .idle
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// The film currently showing in the tab's built-in player. While set,
    /// the setup UI is hidden — like ⌘K in a terminal — and the video takes
    /// the whole tab.
    @Published var nowPlaying: URL?
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var playhead: Double = 0
    @Published var duration: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func play(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        askTask?.cancel()
        askPhase = .idle
        askHistory = []
        nowPlaying = url
        playhead = 0
        duration = 0
        lastPublishedSecond = -1
        loadTimeline(for: url)
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                          queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.playhead = t.seconds
                    if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                    let playing = self.player.rate != 0
                    if playing != self.isPlaying { self.isPlaying = playing; self.publishState() }
                    else if playing { self.publishTick() }
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false; self?.publishState() }
        }
        player.play()
        isPlaying = true
        publishState()
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); isPlaying = false }
        else {
            if duration > 0, playhead >= duration - 0.25 { player.seek(to: .zero) }
            if askPhase != .idle { askTask?.cancel(); askPhase = .idle }
            player.play(); isPlaying = true
        }
        publishState()
    }

    func skip(_ seconds: Double) {
        let target = max(0, min(playhead + seconds, max(duration, 0)))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = target
        publishState()
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(duration, 0)))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = target
        publishState()
    }

    func restart() { seek(to: 0); if player.rate == 0 { player.play(); isPlaying = true } }

    /// Stop: pause, rewind, and return to the setup screen.
    func stopPlaying() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        nowPlaying = nil
        askTask?.cancel()
        askPhase = .idle
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        publishState()
    }

    // MARK: Ask about this moment

    /// One scene of the film with the wall-clock range it occupies in the
    /// MP4, so a timestamp maps back to code lines and narration.
    struct Chapter: Equatable {
        let id: String
        let kind: String
        let heading: String
        let lines: ClosedRange<Int>?
        let narration: String
        let start: Double
        let end: Double
    }

    /// Everything Peeky knows about the paused frame — what the Ask is grounded in.
    struct Moment: Equatable {
        let title: String
        let time: Double
        let chapter: Chapter?
        let sourcePath: String
        let excerpt: String

        var timecode: String { CodeDocumentaryModel.timecode(time) }
        var label: String {
            var s = timecode
            if let h = chapter?.heading, !h.isEmpty { s += " · \(h)" } else if !title.isEmpty { s += " · \(title)" }
            return s
        }
        var codeRef: String {
            guard let lines = chapter?.lines else { return "" }
            let name = (sourcePath as NSString).lastPathComponent
            return lines.count == 1 ? "\(name):\(lines.lowerBound)" : "\(name):\(lines.lowerBound)-\(lines.upperBound)"
        }
    }

    struct Answer: Equatable {
        let question: String
        let text: String
        /// Lines of the source the answer is about — highlighted under the film.
        let lines: ClosedRange<Int>?
        /// False when Claude is inferring rather than reading it off the code.
        let verified: Bool
        /// "Show me" mode: an ordered walkthrough rendered as animated steps.
        let steps: [String]
    }

    enum AskPhase: Equatable {
        case idle
        case listening
        case thinking(String)
        case answered(Answer)
        case failed(String)

        var remoteWord: String {
            switch self {
            case .idle: "IDLE"
            case .listening: "LISTENING"
            case .thinking: "THINKING"
            case .answered: "ANSWERED"
            case .failed: "FAILED"
            }
        }
    }

    @Published var askPhase: AskPhase = .idle {
        didSet { if askPhase != oldValue { publishState() } }
    }
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var filmTitle = ""
    private var sourcePath = ""
    private var sourceLines: [String] = []
    /// Questions asked about this film, oldest first.
    @Published private(set) var askHistory: [Answer] = []

    /// Host hooks (wired by AssistantController).
    var onSpeak: ((String) -> Void)?
    /// Start the Mac mic for a question about the paused frame.
    var onRequestMic: (() -> Void)?
    /// Finish the Mac mic and send whatever was heard.
    var onFinishMic: (() -> Void)?
    /// Words heard so far while the Mac mic is open for a question.
    @Published var liveTranscript = ""
    /// Hand the moment over to the full Peeky Ask tab.
    var onGoDeeper: ((String) -> Void)?
    /// A protocol line for the phone (DOC_STATE / DOC_ANSWER / DOC_RECENT).
    var onRemoteLine: ((String) -> Void)?
    private var lastPublishedSecond = -1
    private var askTask: Task<Void, Never>?
    private var remoteAudioTask: Task<Void, Never>?
    private(set) var remoteReadoutEnabled = false
    private var activeNarratorEngine = "kokoro"
    private var activeNarratorVoice = "am_michael"
    private var activeNarratorSpeed = "0.95"

    var isShowingFilm: Bool { nowPlaying != nil }

    var currentChapter: Chapter? { chapter(at: playhead) }

    func chapter(at t: Double) -> Chapter? {
        chapters.last(where: { $0.start <= t + 0.05 }) ?? chapters.first
    }

    var moment: Moment {
        let ch = currentChapter
        var excerpt = ""
        if let lines = ch?.lines, !sourceLines.isEmpty {
            let lo = max(1, lines.lowerBound), hi = min(sourceLines.count, lines.upperBound)
            if lo <= hi {
                excerpt = (lo...hi).map { String(format: "%4d  %@", $0, sourceLines[$0 - 1]) }.joined(separator: "\n")
            }
        }
        return Moment(title: filmTitle, time: playhead, chapter: ch, sourcePath: sourcePath, excerpt: excerpt)
    }

    /// What a viewer is most likely to want to know here.
    var suggestedQuestions: [String] {
        switch currentChapter?.kind {
        case "code":
            ["Why is this needed?", "Show the failure path", "What could break here?", "Explain this more simply"]
        case "example":
            ["Walk me through this again", "What if the input were empty?", "Where is this tested?"]
        case "list":
            ["Which of these matters most?", "Show me an example", "How would I apply this?"]
        default:
            ["What is this file for?", "Who calls this code?", "Explain this like I'm new to it"]
        }
    }

    /// Ask pressed (Mac or phone): pause, remember the moment, open the mic.
    /// Pressed again while listening, it finishes the question.
    func beginAsk() {
        guard isShowingFilm else { return }
        if askPhase == .listening { onFinishMic?(); return }
        pauseForAsk()
        liveTranscript = ""
        askPhase = .listening
        onRequestMic?()
    }

    /// Ask pressed from the phone: the phone holds the mic, we just pause and show the state.
    func beginAskFromRemote() {
        guard isShowingFilm else { return }
        pauseForAsk()
        askPhase = .listening
    }

    func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        remoteAudioTask?.cancel()
        remoteAudioTask = nil
        liveTranscript = ""
        askPhase = .idle
    }

    private func pauseForAsk() {
        if player.rate != 0 { player.pause(); isPlaying = false }
    }

    /// A question about the paused frame, typed or spoken, from either device.
    func ask(_ question: String, mode: String = "answer") {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShowingFilm, !q.isEmpty else { return }
        pauseForAsk()
        guard let apiKey = KeychainService.anthropicAPIKey(), !apiKey.isEmpty else {
            askPhase = .failed("No Anthropic API key in Keychain.")
            return
        }
        let m = moment
        askPhase = .thinking(q)
        ActivityLog.recordAction("doc-ask", ["q": q, "t": m.timecode])
        askTask?.cancel()
        remoteAudioTask?.cancel()
        askTask = Task { [weak self] in
            do {
                let json = try await AnthropicService(apiKey: apiKey).requestJSON(
                    system: Self.askSystemPrompt(mode: mode),
                    userText: Self.askUserText(moment: m, question: q, mode: mode),
                    maxTokens: 1_200, timeout: 60, effort: "medium")
                guard let self, !Task.isCancelled else { return }
                let answer = Self.parseAnswer(json, question: q, fallbackLines: m.chapter?.lines)
                self.askHistory.append(answer)
                self.askPhase = .answered(answer)
                self.onRemoteLine?("DOC_ANSWER " + answer.text.replacingOccurrences(of: "\n", with: "\u{2028}"))
                let spoken = answer.steps.isEmpty ? answer.text : answer.steps.joined(separator: ". ")
                if self.remoteReadoutEnabled {
                    self.sendNarratorAudio(spoken)
                } else {
                    self.onSpeak?(spoken)
                }
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.askPhase = .failed(error.localizedDescription)
            }
        }
    }

    func askSuggested(_ index: Int) {
        let qs = suggestedQuestions
        guard qs.indices.contains(index) else { return }
        ask(qs[index])
    }

    /// "Show me": re-answer the last question as an animated step walkthrough.
    func showMe() {
        let q: String = switch askPhase {
        case .answered(let a): a.question
        case .thinking(let q): q
        default: "Walk me through what happens in this code, step by step."
        }
        ask(q.isEmpty ? "Walk me through this step by step." : "Show me, step by step: \(q)", mode: "steps")
    }

    /// "Go deeper": open the full Ask tab with the moment attached; playback stays parked here.
    func goDeeper() {
        let m = moment
        var prompt = "I'm watching the code documentary \"\(m.title)\" at \(m.timecode)"
        if let h = m.chapter?.heading, !h.isEmpty { prompt += " (chapter: \(h))" }
        if !m.codeRef.isEmpty { prompt += ", looking at \(m.codeRef)" }
        prompt += "."
        if case .answered(let a) = askPhase {
            prompt += " I asked: \"\(a.question)\" and got: \"\(a.text)\". Go deeper on that."
        } else {
            prompt += " Explain this part of the code in depth."
        }
        if !m.excerpt.isEmpty { prompt += "\n\n```\n\(m.excerpt)\n```" }
        onGoDeeper?(prompt)
    }

    /// Resume the film from the exact frame the question paused it on.
    func resumeDocumentary() {
        askTask?.cancel()
        askPhase = .idle
        if isShowingFilm, player.rate == 0 { player.play(); isPlaying = true }
    }

    // MARK: Remote sync

    /// `DOC_STATE <title>\t<NONE|PLAYING|PAUSED>\t<pos>\t<dur>\t<chapter>\t<code ref>\t<ask phase>\t<q|q|q>`
    func remoteStateLine() -> String {
        func f(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard isShowingFilm else { return "DOC_STATE \tNONE\t0\t0\t\t\tIDLE\t" }
        let m = moment
        let state = isPlaying ? "PLAYING" : "PAUSED"
        return "DOC_STATE " + [f(filmTitle), state, String(format: "%.1f", playhead), String(format: "%.1f", duration),
                               f(m.chapter?.heading ?? ""), f(m.codeRef), askPhase.remoteWord,
                               suggestedQuestions.map(f).joined(separator: "|")].joined(separator: "\t")
    }

    func remoteRecentLine() -> String {
        "DOC_RECENT " + recent.map { $0.title.replacingOccurrences(of: "|", with: "/") }.joined(separator: "|")
    }

    /// Lines the phone should get the moment it connects.
    func remoteGreeting() -> [String] { [remoteRecentLine(), remoteStateLine()] }

    private func publishState() { onRemoteLine?(remoteStateLine()) }

    /// Called from the player's time observer: at most once a second while playing.
    private func publishTick() {
        let s = Int(playhead)
        guard s != lastPublishedSecond else { return }
        lastPublishedSecond = s
        publishState()
    }

    /// Render an interactive answer with the film's narrator, then send the
    /// small WAV to the phone. Audio is opt-in on the phone and stays local.
    private func sendNarratorAudio(_ text: String) {
        remoteAudioTask?.cancel()
        let python = Self.pythonURL
        let narrate = Self.narrateURL
        let engine = activeNarratorEngine
        let voice = activeNarratorVoice
        let speed = activeNarratorSpeed
        let pipeline = Self.pipelineDir
        remoteAudioTask = Task { [weak self] in
            let audio: Data? = await Task.detached(priority: .userInitiated) {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("peeky-doc-answer-\(UUID().uuidString)", isDirectory: true)
                let input = temp.appendingPathComponent("answer.txt")
                let output = temp.appendingPathComponent("answer.m4a")
                defer { try? FileManager.default.removeItem(at: temp) }
                do {
                    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                    try text.write(to: input, atomically: true, encoding: .utf8)
                    let proc = Process()
                    proc.executableURL = python
                    proc.arguments = [narrate.path, "--text-file", input.path, "--output", output.path]
                    proc.currentDirectoryURL = pipeline
                    var env = ProcessInfo.processInfo.environment
                    env["TTS_ENGINE"] = engine
                    switch engine {
                    case "elevenlabs": env["ELEVENLABS_VOICE_ID"] = voice
                    case "say": env["SAY_VOICE"] = voice
                    default:
                        env["KOKORO_VOICE"] = voice
                        env["KOKORO_SPEED"] = speed
                    }
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                    proc.environment = env
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0, !Task.isCancelled else { return nil }
                    return try Data(contentsOf: output)
                } catch {
                    log.error("Could not render documentary answer audio: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            guard !Task.isCancelled, let self, self.remoteReadoutEnabled, let audio else { return }
            self.onRemoteLine?("DOC_AUDIO \(audio.base64EncodedString())")
        }
    }

    /// Phone-side `DOC <action>` commands.
    func handleRemote(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.uppercased() ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "ASK": beginAskFromRemote()
        case "ASK_TEXT": ask(rest)
        case "STOP_ASK": cancelAsk()
        case "PLAYPAUSE": if isShowingFilm { togglePlay() }
        case "SKIP": skip(Double(rest) ?? 10)
        case "SEEK": seek(to: Double(rest) ?? playhead)
        case "RESTART": restart()
        case "RESUME": resumeDocumentary()
        case "SUGGEST": askSuggested(Int(rest) ?? 0)
        case "SHOW_ME": showMe()
        case "DEEPER": goDeeper()
        case "READOUT":
            remoteReadoutEnabled = rest.uppercased() == "ON"
            if !remoteReadoutEnabled {
                remoteAudioTask?.cancel()
                remoteAudioTask = nil
            }
        case "STOP": stopPlaying()
        case "PLAY_RECENT":
            refreshRecent()
            if let i = Int(rest), recent.indices.contains(i) { play(recent[i].url) }
        default: break
        }
    }

    // MARK: Timeline

    /// Reads script.json (+ timeline.json when the pipeline wrote one) from
    /// the film's project folder so timestamps map back to code.
    private func loadTimeline(for film: URL) {
        let dir = film.deletingLastPathComponent()
        chapters = []
        filmTitle = recent.first(where: { $0.url == film })?.title ?? dir.lastPathComponent
        sourcePath = ""
        sourceLines = []
        activeNarratorEngine = "kokoro"
        activeNarratorVoice = voice
        activeNarratorSpeed = "0.95"
        if let vdata = FileManager.default.contents(atPath: dir.appendingPathComponent("audio/voice.json").path),
           let metadata = try? JSONSerialization.jsonObject(with: vdata) as? [String: Any] {
            activeNarratorEngine = metadata["engine"] as? String ?? activeNarratorEngine
            activeNarratorVoice = metadata["voice"] as? String ?? activeNarratorVoice
            if let speed = metadata["speed"] as? NSNumber { activeNarratorSpeed = speed.stringValue }
        }
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("script.json").path),
              let script = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let t = script["title"] as? String, !t.isEmpty { filmTitle = t }
        if let src = script["source"] as? String {
            sourcePath = src
            if let text = try? String(contentsOfFile: src, encoding: .utf8) {
                sourceLines = text.components(separatedBy: "\n")
            }
        }
        var timeline: [String: (Double, Double)] = [:]
        if let tdata = FileManager.default.contents(atPath: dir.appendingPathComponent("timeline.json").path),
           let tjson = try? JSONSerialization.jsonObject(with: tdata) as? [String: Any],
           let entries = tjson["scenes"] as? [[String: Any]] {
            for e in entries {
                if let id = e["id"] as? String, let s = e["start"] as? Double, let en = e["end"] as? Double {
                    timeline[id] = (s, en)
                }
            }
        }
        var durations: [String: Double] = [:]
        if let ddata = FileManager.default.contents(atPath: dir.appendingPathComponent("audio/durations.json").path),
           let d = try? JSONSerialization.jsonObject(with: ddata) as? [String: Double] {
            durations = d
        }
        chapters = Self.buildChapters(script: script, timeline: timeline, durations: durations)
    }

    /// Exact times when the renderer logged them; otherwise an estimate from
    /// narration lengths (+ the pipeline's pad and per-scene animation time).
    static func buildChapters(script: [String: Any], timeline: [String: (Double, Double)],
                              durations: [String: Double]) -> [Chapter] {
        guard let scenes = script["scenes"] as? [[String: Any]] else { return [] }
        var out: [Chapter] = []
        var cursor = 0.0
        for s in scenes {
            guard let id = s["id"] as? String else { continue }
            let kind = s["kind"] as? String ?? ""
            let heading = (s["heading"] as? String) ?? (kind == "title" ? (script["title"] as? String ?? "") : kind.capitalized)
            var lines: ClosedRange<Int>? = nil
            if let r = s["lines"] as? [Any], r.count == 2,
               let a = (r[0] as? NSNumber)?.intValue, let b = (r[1] as? NSNumber)?.intValue, a <= b {
                lines = a...b
            }
            let start: Double, end: Double
            if let exact = timeline[id] {
                (start, end) = exact
            } else {
                let overhead: Double = kind == "title" ? 3.8 : kind == "code" ? 2.2 : 1.6
                start = cursor
                end = cursor + (durations[id] ?? 8) + 0.6 + overhead
            }
            cursor = end
            out.append(Chapter(id: id, kind: kind, heading: heading, lines: lines,
                               narration: s["narration"] as? String ?? "", start: start, end: end))
        }
        return out
    }

    nonisolated static func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Ask prompts

    static func askSystemPrompt(mode: String) -> String {
        let common = """
        You are Peeky, a senior engineer sitting next to a developer who paused a short documentary \
        about one source file. Answer ONLY from the code excerpt and narration you are given; when you \
        must infer something not visible in the excerpt, say so plainly and set "verified": false. \
        Plain, spoken English — this is read aloud. Never paste code back; refer to line numbers. \
        Respond with ONE JSON object and nothing else.
        """
        if mode == "steps" {
            return common + """

            Schema: {"answer": "<one-sentence summary>", "steps": ["<step 1>", "<step 2>", ...], \
            "lines": [start, end], "verified": true|false}
            3–6 steps, each one short sentence describing what happens in order (data in, branch taken, \
            result out). "lines" is the 1-based inclusive range of the excerpt the walkthrough covers.
            """
        }
        return common + """

        Schema: {"answer": "<2–4 sentences>", "lines": [start, end] | null, "verified": true|false}
        "lines" is the 1-based inclusive line range of the excerpt your answer is mostly about (null if none).
        """
    }

    static func askUserText(moment m: Moment, question: String, mode: String) -> String {
        var s = "Documentary: \"\(m.title)\"\nPaused at \(m.timecode)"
        if let ch = m.chapter {
            s += "\nChapter: \(ch.heading) (\(ch.kind))"
            if !ch.narration.isEmpty { s += "\nNarration at this moment: \"\(ch.narration)\"" }
        }
        if !m.sourcePath.isEmpty { s += "\nFile: \((m.sourcePath as NSString).lastPathComponent)" }
        if !m.excerpt.isEmpty { s += "\n\nCode on screen:\n\(m.excerpt)" } else { s += "\n\n(No code is on screen in this chapter.)" }
        s += "\n\nViewer's question: \(question)"
        return s
    }

    static func parseAnswer(_ json: [String: Any], question: String, fallbackLines: ClosedRange<Int>?) -> Answer {
        let text = (json["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = fallbackLines
        if let r = json["lines"] as? [Any], r.count == 2,
           let a = (r[0] as? NSNumber)?.intValue, let b = (r[1] as? NSNumber)?.intValue, a <= b {
            lines = a...b
        }
        let steps = (json["steps"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        return Answer(question: question, text: text.isEmpty ? "I couldn't work that out from what's on screen." : text,
                      lines: lines, verified: (json["verified"] as? Bool) ?? true, steps: steps)
    }

    /// Back to the home screen with a clean slate, ready for another code file.
    func startNew() {
        stopPlaying()
        guard !phase.isRunning else { return }
        sourceFile = nil
        scriptTitle = nil
        logLines = []
        phase = .idle
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func refreshRecent() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.projectsDir, includingPropertiesForKeys: nil) else {
            recent = []
            return
        }
        recent = dirs.compactMap { dir -> Recent? in
            guard !dir.lastPathComponent.hasPrefix("_") else { return nil }
            let mp4 = dir.appendingPathComponent("documentary.mp4")
            guard fm.fileExists(atPath: mp4.path) else { return nil }
            let date = (try? mp4.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var title = dir.lastPathComponent
            if let data = fm.contents(atPath: dir.appendingPathComponent("script.json").path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = json["title"] as? String, !t.isEmpty {
                title = t
            }
            return Recent(id: mp4, title: title, date: date)
        }
        .sorted { $0.date > $1.date }
        onRemoteLine?(remoteRecentLine())
    }

    // MARK: Internals

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    private static func makeProjectDir(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let dir = projectsDir.appendingPathComponent("\(stem.isEmpty ? "code" : stem)-\(stamp)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runPipeline(project: URL, generation gen: Int) async throws {
        let proc = Process()
        proc.executableURL = Self.pythonURL
        proc.arguments = [Self.makeDocURL.path, project.path, "--quality", quality.rawValue]
        proc.currentDirectoryURL = Self.pipelineDir
        var env = ProcessInfo.processInfo.environment
        env["KOKORO_VOICE"] = voice
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["COLUMNS"] = "200"
        // Homebrew's ffmpeg/espeak-ng aren't on a GUI app's PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        process = proc

        var output = URL?.none
        let splitter = LineSplitter()
        let lines = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if let tail = splitter.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in splitter.feed(chunk) { continuation.yield(line) }
            }
        }

        try proc.run()
        for await raw in lines {
            guard gen == generation else { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, Self.isInteresting(line) else { continue }
            if line.hasPrefix("## ") {
                let msg = String(line.dropFirst(3))
                if msg.hasPrefix("Narrating") { phase = .narrating }
                else if msg.hasPrefix("Rendering") { phase = .rendering }
                append("▸ \(msg)")
            } else if line.hasPrefix("OUTPUT ") {
                output = URL(fileURLWithPath: String(line.dropFirst(7)))
            } else {
                append(line)
            }
        }
        proc.waitUntilExit()
        guard gen == generation else { return }
        process = nil
        if proc.terminationStatus == 0, let output {
            phase = .done(output)
            refreshRecent()
        } else {
            throw NSError(domain: "CodeDocumentary", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Pipeline exited with status \(proc.terminationStatus). See the log."])
        }
    }

    /// Manim logs every partial file and cache decision; none of that helps here.
    private static func isInteresting(_ line: String) -> Bool {
        let noise = ["Partial movie file written", "Caching disabled", "Animation ", "scene_file_writer",
                     "cairo_renderer", "max_files_cached", "partial movie directory", "You can change this",
                     "Some options were not used", "'shortest'", "Rendered with Manim", "in config."]
        return !noise.contains { line.contains($0) }
    }

    // MARK: Script writing

    static let scriptSystemPrompt = """
    You write scripts for short, Netflix-style mini documentaries that explain a single source-code file \
    to a developer who learns best by watching. The script is rendered by an animation pipeline, so you \
    answer with ONE JSON object and nothing else — no prose, no code fences.

    Voice: a calm, confident documentary narrator. Concrete, vivid, plain English. Build tension \
    ("here is the problem every test faces…"), then resolve it. Never read code aloud character by \
    character; describe what it does and why it matters. 2–5 sentences per scene. Total runtime 2.5–4 \
    minutes (roughly 350–550 spoken words across all scenes).

    Schema:
    {
      "title": "SHORT PUNCHY TITLE",          // 1–4 words, uppercase feel
      "subtitle": "A short documentary about <file name>",
      "scenes": [ ... 8–12 scenes ... ]
    }

    Scene kinds (every scene has a unique snake_case "id" and a "narration" string):
    1. {"id","kind":"title","narration"}                      — FIRST scene only: the cold open.
    2. {"id","kind":"code","lines":[start,end],"heading","narration","illustration"?}
       Shows lines start..end of the file (1-based, inclusive, 1–22 lines, must exist in the file) \
    with a highlight sweeping down while you narrate. "heading" is 2–6 words. Most scenes are this kind. \
    Walk the file roughly top to bottom; skip boilerplate.
    3. {"id","kind":"example","heading","steps":[["label","value"],...],"narration"}
       A worked example: 3–6 [label, value] pairs shown one by one (e.g. how a function transforms an input).
    4. {"id","kind":"list","heading","items":["...","..."],"narration"}   — 3–5 takeaways, near the end.
    5. {"id","kind":"credits","narration"}                    — LAST scene only, one or two sentences.

    Optional "illustration" on code scenes (use on most of them — pick the metaphor that fits):
      {"type":"flow","steps":["a","b","c"],"caption":"..."}                       — a pipeline of 2–5 steps
      {"type":"compare","left":{"label","value":0..1,"note"?},"right":{"label","value":0..1,"note"?},"caption"?}
                                                                                   — two bars; a "note" on the left is struck out as the wrong idea, on the right shown as the right one
      {"type":"filter","query":"term","total":12,"kept":4,"empty":false,"restore":false,"caption"?}
                                                                                   — a list narrowing under a search; empty=true shows an empty state; restore=true brings it back
      {"type":"pair","left":"A","right":"B","arrow":"relationship","caption"?}     — two collaborators
      {"type":"checklist","items":["..."],"caption"?}                              — 2–6 things ticked off
      {"type":"callout","code":"IDENTIFIER","text":"what it is","bad":"wrong idea"?} — one token explained
    Keep captions and step labels under 5 words; keep illustration text short enough to fit beside code.

    Rules: valid JSON only; ids unique; line ranges inside the file; no markdown anywhere.
    """

    static func writeScript(for code: String, at source: URL, apiKey: String) async throws -> [String: Any] {
        let allLines = code.components(separatedBy: "\n")
        let numbered = allLines.enumerated()
            .map { String(format: "%4d| %@", $0.offset + 1, $0.element) }
            .joined(separator: "\n")
        let user = """
        File: \(source.lastPathComponent)
        Path: \(source.path)
        Lines: \(allLines.count)

        \(numbered)
        """
        let claude = AnthropicService(apiKey: apiKey)
        var json = try await claude.requestJSON(system: scriptSystemPrompt, userText: user,
                                                maxTokens: 9_000, timeout: 240, effort: "high")
        json["source"] = source.path
        try validate(&json, lineCount: allLines.count)
        return json
    }

    /// Repairs what the pipeline can't tolerate: out-of-range lines, missing
    /// or duplicate ids, non-string narration. Throws only when there is
    /// nothing to render.
    static func validate(_ json: inout [String: Any], lineCount: Int) throws {
        guard var scenes = json["scenes"] as? [[String: Any]], !scenes.isEmpty else {
            throw NSError(domain: "CodeDocumentary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Claude's script had no scenes."])
        }
        var seen = Set<String>()
        var kept: [[String: Any]] = []
        for (i, var scene) in scenes.enumerated() {
            guard let kind = scene["kind"] as? String,
                  ["title", "code", "example", "list", "credits"].contains(kind),
                  let narration = scene["narration"] as? String, !narration.isEmpty else { continue }
            var id = (scene["id"] as? String ?? "scene_\(i + 1)")
                .lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            if id.isEmpty { id = "scene_\(i + 1)" }
            while seen.contains(id) { id += "_" }
            seen.insert(id)
            scene["id"] = id
            if kind == "code" {
                guard let range = scene["lines"] as? [Any], range.count == 2,
                      let a = (range[0] as? NSNumber)?.intValue, let b = (range[1] as? NSNumber)?.intValue else { continue }
                let start = max(1, min(a, lineCount))
                let end = max(start, min(b, lineCount, start + 30))
                scene["lines"] = [start, end]
                if scene["heading"] == nil { scene["heading"] = "Lines \(start)–\(end)" }
            }
            if kind == "example", !((scene["steps"] as? [[Any]])?.allSatisfy { $0.count == 2 } ?? false) { continue }
            if kind == "list", (scene["items"] as? [String])?.isEmpty ?? true { continue }
            kept.append(scene)
        }
        guard kept.contains(where: { ($0["kind"] as? String) == "code" }) else {
            throw NSError(domain: "CodeDocumentary", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Claude's script had no usable code scenes."])
        }
        scenes = kept
        json["scenes"] = scenes
        if (json["title"] as? String)?.isEmpty ?? true { json["title"] = "THE CODE" }
        if json["subtitle"] == nil { json["subtitle"] = "A short documentary" }
    }
}

// MARK: - Video surface

/// AVPlayerView without its own controls — the transport bar below it is ours.
private struct DocumentaryVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        return v
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - View

/// Splits a byte stream into lines; used from the pipe's readability
/// handler, which runs on a background queue.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            if let s = String(data: buffer[buffer.startIndex..<nl], encoding: .utf8) { lines.append(s) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(data: buffer, encoding: .utf8)
    }
}

struct CodeDocumentaryView: View {
    @ObservedObject var model: CodeDocumentaryModel
    let accent: Color
    @State private var copiedAnswerPart: String?

    var body: some View {
        Group {
            if let url = model.nowPlaying {
                playerScreen(url)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                setupScreen
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.nowPlaying)
    }

    private var setupScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !model.pipelineReady { setupCard }
                fileCard
                optionsRow
                runRow
                if !model.logLines.isEmpty || model.phase.isRunning { progressCard }
                if case .done(let url) = model.phase { doneCard(url) }
                if case .failed(let message) = model.phase { errorCard(message) }
                if !model.recent.isEmpty { recentCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.setSource(url) }
            }
            return true
        }
        .onAppear { model.refreshRecent() }
    }

    // MARK: Player

    private func playerScreen(_ url: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.stopPlaying() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to Peeky Code Doc home (Esc)")
                Text(model.recent.first(where: { $0.url == url })?.title ?? url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { model.startNew() } label: {
                    Label("New documentary", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.90, green: 0.04, blue: 0.08)))
                }
                .buttonStyle(.plain)
                .help("Go home and pick another code file")
                Button { model.reveal(url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Show in Finder")
                Button { model.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Open in QuickTime")
            }
            .padding(.horizontal, 4)

            DocumentaryVideoSurface(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(alignment: .bottomLeading) { momentBadge.padding(10) }
                .onTapGesture { model.togglePlay() }

            if model.askPhase != .idle {
                askCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            transportBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: model.askPhase)
    }

    // MARK: Ask about this moment

    /// Timestamp + chapter, always visible on the film so Ask has an obvious anchor.
    private var momentBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble.fill").font(.system(size: 11.5, weight: .bold))
            Text(model.askPhase == .idle ? "Ask about \(model.moment.label)" : model.moment.label)
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .allowsHitTesting(false)
    }

    private var askButton: some View {
        Button { model.beginAsk() } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text("Ask")
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(height: 36)
            .padding(.horizontal, 14)
            .background(Capsule().fill(accent))
        }
        .buttonStyle(.plain)
        .help("Pause and ask about this moment (⌘/)")
        .keyboardShortcut("/", modifiers: .command)
    }

    @ViewBuilder private var askCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(accent)
                Text("Ask about \(model.moment.label)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !model.moment.codeRef.isEmpty {
                    Text(model.moment.codeRef)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            switch model.askPhase {
            case .idle:
                EmptyView()
            case .listening:
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(accent).symbolEffect(.pulse)
                    if model.liveTranscript.isEmpty {
                        Text("Listening… ask your question. It sends itself when you pause (the first words take a moment to appear).")
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        Text("“\(model.liveTranscript)”")
                            .italic().foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    Button("Done") { model.beginAsk() }.buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                    Button("Cancel") { model.cancelAsk() }.buttonStyle(.bordered).controlSize(.small)
                }
                .font(.system(size: 14))
                .lineLimit(2)
                suggestionChips
            case .thinking(let q):
                questionBubble(q)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Peeky is answering from the code on screen…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(responseBubbleBackground)
            case .answered(let a):
                answerBody(a)
                answerActions
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14)).foregroundStyle(.orange)
                answerActions
            }
        }
        .padding(12)
        .background(card)
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.suggestedQuestions.enumerated()), id: \.offset) { i, q in
                    Button { model.askSuggested(i) } label: {
                        Text(q)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func answerBody(_ a: CodeDocumentaryModel.Answer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBubble(a.question)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("PEEKY · RESPONSE")
                }
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.green.opacity(0.9))
                Text(a.text)
                    .font(.system(size: 17, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !a.steps.isEmpty { stepsView(a.steps) }
                if let lines = a.lines, let excerpt = highlightedExcerpt(lines) { excerpt }
                HStack(spacing: 6) {
                    Image(systemName: a.verified ? "checkmark.seal.fill" : "questionmark.circle")
                    Text(a.verified ? "Read from the code on screen" : "Peeky's interpretation — not verified in the code shown")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(a.verified ? Color.green.opacity(0.8) : Color.orange.opacity(0.85))
                HStack {
                    Spacer()
                    copyAnswerButton(a.text, key: "response", help: "Copy Peeky's response")
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(responseBubbleBackground)
        }
    }

    private func questionBubble(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                Text("YOU · ASKED")
            }
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(accent)
            Text(question)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                copyAnswerButton(question, key: "question", help: "Copy your question")
            }
        }
        .padding(12)
        .frame(maxWidth: 900, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                )
                .overlay(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(accent.opacity(0.9))
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .padding(.trailing, 3)
                }
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var responseBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 3)
            }
    }

    private func copyAnswerButton(_ text: String, key: String, help: String) -> some View {
        let copied = copiedAnswerPart == key
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedAnswerPart = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedAnswerPart == key { copiedAnswerPart = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if copied { Text("Copied") }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(copied ? Color.green : .white.opacity(0.55))
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// "Show me": the walkthrough lands one step at a time.
    private func stepsView(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(accent))
                    Text(step).font(.system(size: 15, weight: .regular)).foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .animation(.easeOut(duration: 0.35).delay(Double(i) * 0.25), value: steps.count)
            }
        }
        .padding(.vertical, 2)
    }

    /// The chapter's code with the answer's lines lit in the accent colour.
    private func highlightedExcerpt(_ lines: ClosedRange<Int>) -> AnyView? {
        let excerpt = model.moment.excerpt
        guard !excerpt.isEmpty else { return nil }
        let rows = excerpt.components(separatedBy: "\n")
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let n = Int(row.prefix(4).trimmingCharacters(in: .whitespaces)) ?? -1
                    let hot = lines.contains(n)
                    Text(row)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(hot ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 8).padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hot ? accent.opacity(0.22) : .clear)
                        .overlay(alignment: .leading) {
                            if hot { Rectangle().fill(accent).frame(width: 3) }
                        }
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
        )
    }

    private var answerActions: some View {
        HStack(spacing: 8) {
            Button { model.resumeDocumentary() } label: {
                Label("Resume documentary", systemImage: "play.fill")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            Button { model.showMe() } label: { Label("Show me", systemImage: "list.number") }
            Button { model.goDeeper() } label: { Label("Go deeper", systemImage: "arrow.up.right.square") }
            Button { model.beginAsk() } label: { Label("Ask another", systemImage: "mic.fill") }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 13))
    }

    private var transportBar: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { model.playhead },
                                  set: { model.seek(to: $0) }),
                   in: 0...max(model.duration, 0.01))
                .tint(accent)
            HStack(spacing: 6) {
                Text(timecode(model.playhead))
                Spacer(minLength: 0)
                transportButton("backward.end.fill", help: "Restart") { model.restart() }
                transportButton("gobackward.10", help: "Back 10 seconds (←)") { model.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (space)" : "Play (space)")
                transportButton("goforward.10", help: "Forward 10 seconds (→)") { model.skip(10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                transportButton("stop.fill", help: "Stop and go back") { model.stopPlaying() }
                Spacer(minLength: 0)
                askButton
                Text(timecode(model.duration))
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(12)
        .background(card)
    }

    private func transportButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Turn a code file into a mini documentary")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Claude writes the script · narration and animation render on this Mac · nothing else leaves it")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pipeline not found", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.9))
            Text("Expected \(CodeDocumentaryModel.pipelineDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) with make_doc.py and a .venv. Run tools/code-documentary/setup.sh from the MyClicky repo, or point Peeky elsewhere:")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
            Text("defaults write MyClicky documentaryPipelineDir /path/to/code-documentary")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var fileCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.sourceFile == nil ? "doc.badge.plus" : "doc.text.fill")
                .font(.system(size: 22))
                .foregroundStyle(model.sourceFile == nil ? .white.opacity(0.35) : accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                if let file = model.sourceFile {
                    Text(file.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(file.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("Drop a code file here")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("or click to choose one, or paste a path in the box below")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.sourceFile == nil ? "Choose…" : "Change…") { model.pickFile() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.phase.isRunning)
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if !model.phase.isRunning { model.pickFile() } }
        .help("Click to choose a file, or drop one here")
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: model.sourceFile == nil ? [6, 5] : []))
                .foregroundStyle(model.sourceFile == nil ? .white.opacity(0.18) : accent.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        )
    }

    private var optionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { voicePicker; qualityPicker; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { voicePicker; qualityPicker }
        }
        .font(.system(size: 12))
        .disabled(model.phase.isRunning)
    }

    private var voicePicker: some View {
        Picker("Voice", selection: $model.voice) {
            ForEach(CodeDocumentaryModel.voices) { Text($0.label).tag($0.id) }
        }
        .frame(maxWidth: 260)
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: $model.quality) {
            ForEach(CodeDocumentaryModel.Quality.allCases) { Text($0.label).tag($0) }
        }
        .frame(maxWidth: 220)
    }

    private var canGenerate: Bool { model.sourceFile != nil && model.pipelineReady }

    private var runRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.phase.isRunning {
                Button(role: .cancel) { model.cancel() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
            } else {
                Button { model.generate() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Make documentary")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(canGenerate ? Color(red: 0.90, green: 0.04, blue: 0.08) : Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canGenerate)
                .keyboardShortcut(.return, modifiers: .command)
                .help(canGenerate ? "Write the script, narrate and render (⌘↩)" : "Choose a code file first")
            }
            HStack {
                if let title = model.scriptTitle {
                    Text("“\(title)”")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(canGenerate ? "⌘↩ · renders in 1–3 min" : "choose a code file above to enable")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                step("Script", done: stepIndex > 0, active: model.phase == .writingScript)
                step("Narration", done: stepIndex > 1, active: model.phase == .narrating)
                step("Animation", done: stepIndex > 2, active: model.phase == .rendering)
                step("Film", done: stepIndex > 2 && !model.phase.isRunning, active: false)
                Spacer(minLength: 0)
                if model.phase.isRunning { ProgressView().controlSize(.small) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("▸") ? .white.opacity(0.9)
                                                 : line.hasPrefix("✗") ? .red.opacity(0.9)
                                                 : .white.opacity(0.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                }
                .frame(height: 130)
                .onChange(of: model.logLines.count) { _, n in
                    if n > 0 { withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
                }
            }
        }
        .padding(12)
        .background(card)
    }

    private var stepIndex: Int {
        switch model.phase {
        case .idle, .failed: model.logLines.isEmpty ? 0 : 1
        case .writingScript: 0
        case .narrating: 1
        case .rendering: 2
        case .done: 3
        }
    }

    private func step(_ label: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? accent : active ? .white.opacity(0.9) : .white.opacity(0.25))
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(done || active ? .white.opacity(0.9) : .white.opacity(0.35))
        }
    }

    private func doneCard(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your documentary is ready")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button { model.play(url) } label: { Label("Watch", systemImage: "play.rectangle.fill") }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            Button { model.reveal(url) } label: { Image(systemName: "folder") }
                .buttonStyle(.bordered)
                .help("Show in Finder")
        }
        .padding(14)
        .background(card)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red.opacity(0.85))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(card)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            ForEach(model.recent.prefix(6)) { item in
                HStack(spacing: 10) {
                    Image(systemName: "film")
                        .foregroundStyle(.white.opacity(0.5))
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(item.date, style: .relative)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Button { model.play(item.url) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                    Button { model.reveal(item.url) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }
}
