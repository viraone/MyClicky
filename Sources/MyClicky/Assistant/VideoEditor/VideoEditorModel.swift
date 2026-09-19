import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// The Peeky Video tab: one open project, its preview player, and the
/// long-running jobs (captioning, export). The panel owns one of these for
/// as long as it lives, so switching tabs doesn't lose the edit.
@MainActor
final class VideoEditorModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing(Int, Int)
        case transcribing(String, Int, Int)
        case exporting(Double)
        case exported(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .importing, .transcribing, .exporting: true
            default: false
            }
        }
    }

    /// Where projects live: one folder each, alongside the user's other
    /// videos rather than hidden in Application Support — they'll want to
    /// hand the exports to CapCut or a portfolio site.
    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Peeky Video Projects", isDirectory: true)

    @Published private(set) var project: VideoProject? { didSet { publishRemoteState() } }
    @Published private(set) var projectFolder: URL?
    @Published private(set) var recentProjects: [URL] = []
    @Published var selectedClipID: UUID? { didSet { publishRemoteState() } }
    @Published private(set) var phase: Phase = .idle { didSet { publishRemoteState() } }
    @Published private(set) var currentTime: Double = 0 {
        didSet {
            // Thirty updates a second while playing; the phone only needs a
            // few to keep its timecode moving.
            let tick = Int(currentTime * 5)
            if tick != lastPublishedTick { lastPublishedTick = tick; publishRemoteState() }
        }
    }
    @Published private(set) var isPlaying = false { didSet { if isPlaying != oldValue { publishRemoteState() } } }
    /// The last thing worth telling the user, under the toolbar.
    @Published private(set) var note: String?
    /// The most recent finished export this session, so the step tracker
    /// can show Export as done.
    @Published private(set) var lastExport: URL?
    var style = CaptionStyle()

    /// A protocol line for the Peeky Remote phone app (VIDEO_STATE).
    var onRemoteLine: ((String) -> Void)?
    private var lastPublishedTick = -1

    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var previewGeneration = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                self.isPlaying = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        refreshRecentProjects()
    }

    var hasProject: Bool { project != nil }
    var duration: Double { project?.duration ?? 0 }
    var currentCue: TimelineCue? { project?.cue(at: currentTime) }
    var selectedClip: EditClip? {
        guard let selectedClipID else { return nil }
        return project?.clips.first { $0.id == selectedClipID }
    }
    var exportsFolder: URL? { projectFolder?.appendingPathComponent("exports", isDirectory: true) }

    // MARK: Projects

    func refreshRecentProjects() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.projectsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        recentProjects = folders
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(VideoProject.fileName).path) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// A folder name that's safe on disk and unique under the projects root.
    static func folderName(for name: String, existing: (String) -> Bool) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        if base.isEmpty { base = "Untitled" }
        var candidate = base
        var n = 2
        while existing(candidate) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    func newProject(named name: String) {
        let fm = FileManager.default
        let folderName = Self.folderName(for: name) { fm.fileExists(atPath: Self.projectsRoot.appendingPathComponent($0).path) }
        let folder = Self.projectsRoot.appendingPathComponent(folderName, isDirectory: true)
        let project = VideoProject(name: folderName)
        do {
            try project.save(to: folder)
        } catch {
            phase = .failed("Couldn't create the project folder: \(error.localizedDescription)")
            return
        }
        load(project, from: folder)
        note = "New project — import your takes, or drop them here."
    }

    func open(folder: URL) {
        do {
            let project = try VideoProject.load(from: folder)
            load(project, from: folder)
            let missing = project.clips.filter { !FileManager.default.fileExists(atPath: $0.source.path) }
            note = missing.isEmpty ? nil : "\(missing.count) clip\(missing.count == 1 ? "" : "s") can't be found on disk."
        } catch {
            phase = .failed("Couldn't open that project: \(error.localizedDescription)")
        }
    }

    func closeProject() {
        player.replaceCurrentItem(with: nil)
        project = nil
        projectFolder = nil
        selectedClipID = nil
        currentTime = 0
        phase = .idle
        note = nil
        waveforms = [:]
        refreshRecentProjects()
    }

    private func load(_ project: VideoProject, from folder: URL) {
        self.project = project
        projectFolder = folder
        selectedClipID = project.clips.first?.id
        phase = .idle
        currentTime = 0
        lastExport = nil
        waveforms = [:]
        refreshRecentProjects()
        rebuildPreview(seekTo: 0)
        loadWaveforms()
    }

    /// What typing in the panel's input does here: name a new project.
    func submit(_ text: String) {
        if project == nil { newProject(named: text) }
    }

    private func save() {
        guard let project, let projectFolder else { return }
        do { try project.save(to: projectFolder) } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Change the project, save it, and refresh the preview at `seek`
    /// (or where the playhead is).
    private func edit(seekTo requested: Double? = nil, _ change: (inout VideoProject) -> Void) {
        guard var p = project else { return }
        change(&p)
        project = p
        save()
        rebuildPreview(seekTo: requested)
    }

    // MARK: Clips

    static let importableTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .audiovisualContent]

    func chooseClips() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.importableTypes
        panel.message = "Choose the takes and screen recordings for this video"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importClips(panel.urls)
    }

    func importClips(_ urls: [URL]) {
        let videos = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audiovisualContent)
        }
        guard !videos.isEmpty else {
            note = "Those aren't video files."
            return
        }
        if project == nil {
            // Dropping clips onto the start screen starts a project named
            // after the first take, so nothing has to be typed first.
            newProject(named: videos[0].deletingPathExtension().lastPathComponent)
            guard project != nil else { return }
        }
        Task { await importVideos(videos) }
    }

    private func importVideos(_ urls: [URL]) async {
        var added = 0
        var skipped: [String] = []
        for (index, url) in urls.enumerated() {
            phase = .importing(index + 1, urls.count)
            let asset = AVURLAsset(url: url)
            guard let seconds = try? await asset.load(.duration).seconds, seconds > 0,
                  let hasVideo = try? await !asset.loadTracks(withMediaType: .video).isEmpty, hasVideo else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let clip = EditClip(source: url, sourceDuration: seconds)
            guard var p = project else { return }
            p.append(clip)
            project = p
            selectedClipID = clip.id
            added += 1
        }
        save()
        phase = .idle
        note = skipped.isEmpty
            ? "Added \(added) clip\(added == 1 ? "" : "s")."
            : "Added \(added); couldn't read \(skipped.joined(separator: ", "))."
        rebuildPreview(seekTo: nil)
        loadWaveforms()
    }

    // MARK: Waveforms

    /// Loudness peaks per source path, drawn inside the timeline clips.
    /// Read once per file and cached beside the project as
    /// `waveforms.json` so reopening is instant.
    @Published private(set) var waveforms: [String: [Float]] = [:]
    private var waveformTasks: Set<String> = []
    private static let waveformsFile = "waveforms.json"

    private func loadWaveforms() {
        guard let project, let projectFolder else { return }
        if waveforms.isEmpty,
           let data = try? Data(contentsOf: projectFolder.appendingPathComponent(Self.waveformsFile)),
           let cached = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            waveforms = cached
        }
        for url in project.clips.map(\.source) {
            let key = url.path
            guard waveforms[key] == nil, !waveformTasks.contains(key) else { continue }
            waveformTasks.insert(key)
            Task { [weak self] in
                let peaks = try? await AudioWaveform.peaks(for: url)
                guard let self else { return }
                // A silent or audio-less clip still gets an entry so we
                // don't try again on every open.
                self.waveforms[key] = peaks ?? []
                self.waveformTasks.remove(key)
                self.saveWaveforms()
            }
        }
    }

    private func saveWaveforms() {
        guard let projectFolder, let data = try? JSONEncoder().encode(waveforms) else { return }
        try? data.write(to: projectFolder.appendingPathComponent(Self.waveformsFile), options: .atomic)
    }

    /// Bars for one clip at a given pixel width — what the timeline draws.
    func waveformBars(for clip: EditClip, count: Int) -> [Float]? {
        guard let peaks = waveforms[clip.source.path], !peaks.isEmpty else { return nil }
        return AudioWaveform.bars(from: peaks, sourceDuration: clip.sourceDuration,
                                  inPoint: clip.inPoint, outPoint: clip.outPoint, count: count)
    }

    func removeSelectedClip() {
        guard let id = selectedClipID, let p = project, let index = p.clips.firstIndex(where: { $0.id == id }) else { return }
        edit(seekTo: p.clipStarts[index]) { $0.remove(id) }
        selectedClipID = project?.clips[safe: min(index, (project?.clips.count ?? 1) - 1)]?.id
    }

    func moveSelectedClip(by offset: Int) {
        guard let id = selectedClipID else { return }
        edit { p in p.move(id, by: offset) }
        // Follow the clip to its new place.
        if let start = project?.start(of: id) { seek(to: start) }
    }

    func splitAtPlayhead() {
        let t = currentTime
        edit(seekTo: t) { p in
            if !p.split(at: t) { self.note = "Too close to the edge of the clip to split there." }
        }
        if let (index, _) = project?.locate(t) { selectedClipID = project?.clips[index].id }
    }

    func trimStartToPlayhead() {
        let t = currentTime
        guard let (index, _) = project?.locate(t), let start = project?.clipStarts[index] else { return }
        edit(seekTo: start) { p in
            if !p.trimStart(at: t) { self.note = "Nothing to trim there." }
        }
    }

    func trimEndToPlayhead() {
        let t = currentTime
        edit(seekTo: max(0, t - 0.05)) { p in
            if !p.trimEnd(at: t) { self.note = "Nothing to trim there." }
        }
    }

    // MARK: Zoom

    /// Zoom the clip under the playhead. The preview is rebuilt so it shows
    /// exactly what will export.
    func setZoom(_ zoom: Double) {
        guard let id = selectedClipID else { return }
        let t = currentTime
        edit(seekTo: t) { $0.setZoom(zoom, for: id) }
    }

    func zoom(by factor: Double) {
        guard let clip = selectedClip else { return }
        setZoom(clip.zoom * factor)
    }

    /// Just enough zoom that the picture covers the whole 9:16 frame.
    func zoomToFill() {
        guard let clip = selectedClip else { return }
        Task {
            let asset = AVURLAsset(url: clip.source)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, preferred) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            setZoom(VideoExporter.fillZoom(naturalSize: natural, preferredTransform: preferred))
        }
    }

    // MARK: Captions

    func setCueText(_ id: UUID, _ text: String) {
        guard var p = project else { return }
        p.setCueText(id, text)
        project = p
        save()
    }

    func removeCue(_ id: UUID) {
        guard var p = project else { return }
        p.removeCue(id)
        project = p
        save()
    }

    /// Listen to every take that hasn't been heard yet, then lay captions
    /// on every clip. Editing the words afterwards is the user's job.
    func generateCaptions() {
        guard let project, !project.clips.isEmpty else {
            note = "Import a clip first."
            return
        }
        Task { await transcribeAndCaption() }
    }

    private func transcribeAndCaption() async {
        guard var p = project else { return }
        let pending = p.untranscribedSources
        for (index, url) in pending.enumerated() {
            phase = .transcribing(url.lastPathComponent, index + 1, pending.count)
            do {
                let words = try await VideoTranscriber.words(in: url)
                guard var current = project else { return }
                current.transcripts[url.path] = words
                project = current
                p = current
            } catch {
                phase = .failed(error.localizedDescription)
                save()
                return
            }
        }
        p.recaptionAll()
        project = p
        save()
        phase = .idle
        let count = p.timelineCues.count
        note = count == 0 ? "Didn't hear any words in these clips." : "\(count) caption\(count == 1 ? "" : "s") ready — fix any wording below."
    }

    // MARK: Preview

    private func rebuildPreview(seekTo requested: Double?) {
        guard let project else {
            player.replaceCurrentItem(with: nil)
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        let wasPlaying = isPlaying
        let target = requested ?? currentTime
        Task {
            do {
                let timeline = try await VideoExporter.build(project)
                guard generation == previewGeneration else { return }
                let item = AVPlayerItem(asset: timeline.composition)
                item.videoComposition = timeline.videoComposition
                player.replaceCurrentItem(with: item)
                seek(to: min(target, max(0, project.duration - 0.05)))
                if wasPlaying { player.play() }
            } catch VideoExporter.Failure.noClips {
                guard generation == previewGeneration else { return }
                player.replaceCurrentItem(with: nil)
                currentTime = 0
            } catch {
                guard generation == previewGeneration else { return }
                note = "Preview failed: \(error.localizedDescription)"
            }
        }
    }

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: VideoExporter.timescale),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        // The cut buttons act on the clip under the playhead, so keep the
        // selection following it — no separate "select" step to learn.
        if let (index, _) = project?.locate(clamped), let id = project?.clips[safe: index]?.id {
            selectedClipID = id
        }
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        if let start = project?.start(of: id) { seek(to: start) }
    }

    // MARK: Export

    func export() {
        guard let project, let exportsFolder else { return }
        guard !project.clips.isEmpty else {
            note = "Import a clip first."
            return
        }
        player.pause()
        let stamp = Self.stampFormatter.string(from: Date())
        let base = exportsFolder.appendingPathComponent("\(project.name) \(stamp)")
        let movie = base.appendingPathExtension("mp4")
        phase = .exporting(0)
        Task {
            do {
                try await VideoExporter.export(project, style: style, to: movie) { [weak self] p in
                    self?.phase = .exporting(p)
                }
                try? project.srt.write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                try? project.transcript.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                phase = .exported(movie)
                lastExport = movie
                note = "Saved \(movie.lastPathComponent) with its .srt and transcript."
                NSWorkspace.shared.activateFileViewerSelecting([movie])
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Remote (Peeky Remote on the phone)

    /// One frame at the export rate — the step the phone's dial moves by.
    static let frameStep = 1.0 / 30.0

    /// `VIDEO_STATE <project>\t<NONE|PLAYING|PAUSED>\t<pos>\t<dur>\t<clip name>\t<clip #>\t<clip count>\t<zoom>\t<captions 0|1>\t<phase>`
    func remoteStateLine() -> String {
        let f: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard let project else { return "VIDEO_STATE \tNONE\t0\t0\t\t0\t0\t1\t0\tIDLE" }
        let clip = selectedClip
        let index = project.clips.firstIndex { $0.id == clip?.id }.map { $0 + 1 } ?? 0
        let phaseName: String
        switch phase {
        case .idle: phaseName = "IDLE"
        case .importing: phaseName = "IMPORTING"
        case .transcribing: phaseName = "TRANSCRIBING"
        case .exporting: phaseName = "EXPORTING"
        case .exported: phaseName = "EXPORTED"
        case .failed: phaseName = "FAILED"
        }
        return "VIDEO_STATE " + [f(project.name), isPlaying ? "PLAYING" : "PAUSED",
                                 String(format: "%.2f", currentTime), String(format: "%.2f", duration),
                                 f(clip?.name ?? ""), String(index), String(project.clips.count),
                                 String(format: "%.2f", clip?.zoom ?? 1),
                                 (clip?.cues.isEmpty == false) ? "1" : "0", phaseName].joined(separator: "\t")
    }

    private func publishRemoteState() { onRemoteLine?(remoteStateLine()) }

    /// A command from the phone's Peeky Video pad — the same buttons as the
    /// tab, plus the dial (JOG / TRIM_START / TRIM_END in frames).
    func handleRemote(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let number = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        switch verb {
        case "PLAYPAUSE": if hasProject { togglePlay() }
        case "START": seek(to: 0)
        case "SKIP": seek(to: currentTime + (number ?? 5))
        case "SEEK": if let number { seek(to: number) }
        case "JOG":
            if isPlaying { player.pause() }
            seek(to: currentTime + (number ?? 1) * Self.frameStep)
        case "TRIM_START": nudgeSelectedClipStart(byFrames: number ?? 1)
        case "TRIM_END": nudgeSelectedClipEnd(byFrames: number ?? 1)
        case "SPLIT": splitAtPlayhead()
        case "CUT_BEFORE": trimStartToPlayhead()
        case "CUT_AFTER": trimEndToPlayhead()
        case "ZOOM_IN": zoom(by: 1.15)
        case "ZOOM_OUT": zoom(by: 1 / 1.15)
        case "FILL": zoomToFill()
        case "FIT": setZoom(1)
        case "EARLIER": moveSelectedClip(by: -1)
        case "LATER": moveSelectedClip(by: 1)
        case "REMOVE": removeSelectedClip()
        case "CAPTIONS": if !phase.isBusy { generateCaptions() }
        case "EXPORT": if !phase.isBusy { export() }
        default: break
        }
    }

    /// Dial in Trim-start mode: slide the selected clip's first frame and
    /// park the playhead on it so the cut is what's on screen.
    func nudgeSelectedClipStart(byFrames frames: Double) {
        guard let id = selectedClipID else { return }
        if isPlaying { player.pause() }
        var moved = false
        edit { p in moved = p.nudgeStart(id, by: frames * Self.frameStep) }
        if moved, let start = project?.start(of: id) { seek(to: start) }
    }

    /// Dial in Trim-end mode: slide the selected clip's last frame.
    func nudgeSelectedClipEnd(byFrames frames: Double) {
        guard let id = selectedClipID else { return }
        if isPlaying { player.pause() }
        var moved = false
        edit { p in moved = p.nudgeEnd(id, by: frames * Self.frameStep) }
        if moved, let start = project?.start(of: id), let clip = selectedClip {
            seek(to: max(start, start + clip.duration - Self.frameStep))
        }
    }

    func revealProject() {
        guard let projectFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([projectFolder])
    }

    func dismissPhase() { phase = .idle }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s / 60)
        let rest = s - Double(m) * 60
        return String(format: "%d:%05.2f", m, rest)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
