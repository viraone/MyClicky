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
        nowPlaying = url
        playhead = 0
        duration = 0
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                          queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.playhead = t.seconds
                    if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
                    self.isPlaying = self.player.rate != 0
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        player.play()
        isPlaying = true
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); isPlaying = false }
        else {
            if duration > 0, playhead >= duration - 0.25 { player.seek(to: .zero) }
            player.play(); isPlaying = true
        }
    }

    func skip(_ seconds: Double) {
        let target = max(0, min(playhead + seconds, max(duration, 0)))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = target
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = seconds
    }

    func restart() { seek(to: 0); if player.rate == 0 { player.play(); isPlaying = true } }

    /// Stop: pause, rewind, and return to the setup screen.
    func stopPlaying() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        nowPlaying = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
                Text(model.recent.first(where: { $0.url == url })?.title ?? url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
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
                .onTapGesture { model.togglePlay() }

            transportBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
