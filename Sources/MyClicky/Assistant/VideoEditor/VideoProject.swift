import Foundation

/// One caption on screen. Times are in the *source clip's* seconds, so a
/// cue rides along with its clip when the clip is moved, split or trimmed;
/// `VideoProject.timelineCues` maps them onto the finished video.
struct CaptionCue: Codable, Equatable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    /// The same line in the project's translation language, when the user
    /// turned "Add translation" on. Shown under the original.
    var translation: String?
    /// Its own spot on the video once detached from the rest, or nil to
    /// sit where every other line does.
    var anchor: CaptionAnchor?

    init(id: UUID = UUID(), start: Double, end: Double, text: String, translation: String? = nil, anchor: CaptionAnchor? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
        self.anchor = anchor
    }

    var duration: Double { max(0, end - start) }
}

/// One word as the recognizer heard it, in source seconds.
struct SpokenWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// A stretch of one source file on the timeline. `inPoint`/`outPoint` are
/// source seconds; the clip's timeline position is its index in the project.
struct EditClip: Codable, Equatable, Identifiable {
    var id: UUID
    /// Where the footage lives. Referenced, never copied: a 4K take is big.
    var source: URL
    var sourceDuration: Double
    var inPoint: Double
    var outPoint: Double
    /// Captions for this stretch, in source seconds. Empty until the user
    /// generates them; kept through moves, splits and trims.
    var cues: [CaptionCue]
    /// How far the picture is zoomed into the 9:16 frame. 1 fits the whole
    /// clip (letterboxed if it's landscape); bigger crops in from the centre.
    var zoom: Double
    /// How far the zoomed picture has been moved off-centre, as a share of
    /// the frame width and height: positive is right and down. Kept within
    /// the picture's spare edge so black never shows.
    var panX: Double
    var panY: Double

    static let minZoom = 1.0
    static let maxZoom = 4.0

    init(id: UUID = UUID(), source: URL, sourceDuration: Double, inPoint: Double = 0, outPoint: Double? = nil, cues: [CaptionCue] = [],
         zoom: Double = 1, panX: Double = 0, panY: Double = 0) {
        self.id = id
        self.source = source
        self.sourceDuration = sourceDuration
        self.inPoint = inPoint
        self.outPoint = outPoint ?? sourceDuration
        self.cues = cues
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
    }

    private enum CodingKeys: String, CodingKey { case id, source, sourceDuration, inPoint, outPoint, cues, zoom, panX, panY }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(URL.self, forKey: .source)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration)
        inPoint = try c.decode(Double.self, forKey: .inPoint)
        outPoint = try c.decode(Double.self, forKey: .outPoint)
        cues = try c.decode([CaptionCue].self, forKey: .cues)
        // Projects saved before zoom existed show every clip fitted.
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        panX = try c.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try c.decodeIfPresent(Double.self, forKey: .panY) ?? 0
    }

    var duration: Double { max(0, outPoint - inPoint) }
    var name: String { source.deletingPathExtension().lastPathComponent }
}

/// A caption placed on the finished video, in timeline seconds.
struct TimelineCue: Equatable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var translation: String? = nil
    /// Set when the line is detached and has its own spot on the video.
    var anchor: CaptionAnchor? = nil

    /// What goes on screen: the line, with its translation beneath if
    /// there is one.
    var displayText: String {
        guard let translation, !translation.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        return text + "\n" + translation
    }
}

/// Everything the editor needs to rebuild a video: an ordered list of clips
/// plus their captions. Saved as `project.json` in the project folder.
/// Where the subtitles sit on the video, dragged there in the preview:
/// the caption's centre as a share of the frame width, and of the frame
/// height measured from the bottom.
struct CaptionAnchor: Codable, Equatable {
    var x: Double
    var y: Double
}

struct VideoProject: Codable, Equatable {
    static let currentVersion = 1
    /// The shortest clip the editor will make — a split or trim closer than
    /// this to an edge is refused rather than leaving a sliver.
    static let minimumClipDuration = 0.1
    static let defaultSpokenLanguage = "en-US"
    /// Bumped when the listener changes enough that old transcripts should
    /// be thrown away and every take heard again: 1 was SFSpeechRecognizer,
    /// 2 is SpeechAnalyzer.
    static let currentTranscriptVersion = 2

    var version = VideoProject.currentVersion
    var name: String
    var clips: [EditClip]
    var created: Date
    /// Every word heard in each source file, by path, so re-captioning
    /// after a split or trim doesn't listen to the whole take again.
    var transcripts: [String: [SpokenWord]]
    /// Which listener made `transcripts`; see `currentTranscriptVersion`.
    var transcriptVersion = VideoProject.currentTranscriptVersion
    /// The locale the takes are spoken in — what the recogniser listens for.
    var spokenLanguage: String
    /// A language to add under every subtitle, or nil for none.
    var translationLanguage: String?
    /// The look of every subtitle — a `SubtitleStylePreset` by name.
    var subtitleStyle: String
    /// Where the subtitles were dragged to, or nil for the style's own spot.
    var captionAnchor: CaptionAnchor?
    /// The shape of the finished video — a `FrameFormat` by id.
    var frameFormat: String

    init(name: String, clips: [EditClip] = [], created: Date = Date(), transcripts: [String: [SpokenWord]] = [:],
         spokenLanguage: String = VideoProject.defaultSpokenLanguage, translationLanguage: String? = nil,
         subtitleStyle: String = SubtitleStylePreset.default.rawValue, frameFormat: String = FrameFormat.default.id) {
        self.name = name
        self.clips = clips
        self.created = created
        self.transcripts = transcripts
        self.spokenLanguage = spokenLanguage
        self.translationLanguage = translationLanguage
        self.subtitleStyle = subtitleStyle
        self.frameFormat = frameFormat
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, clips, created, transcripts, transcriptVersion, spokenLanguage, translationLanguage, subtitleStyle, captionAnchor,
             frameFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decode([EditClip].self, forKey: .clips)
        created = try c.decode(Date.self, forKey: .created)
        transcripts = try c.decodeIfPresent([String: [SpokenWord]].self, forKey: .transcripts) ?? [:]
        // Saved before the field existed means the old recogniser made them.
        transcriptVersion = try c.decodeIfPresent(Int.self, forKey: .transcriptVersion) ?? 1
        // Projects saved before languages existed were all English.
        spokenLanguage = try c.decodeIfPresent(String.self, forKey: .spokenLanguage) ?? Self.defaultSpokenLanguage
        translationLanguage = try c.decodeIfPresent(String.self, forKey: .translationLanguage)
        subtitleStyle = try c.decodeIfPresent(String.self, forKey: .subtitleStyle) ?? SubtitleStylePreset.default.rawValue
        captionAnchor = try c.decodeIfPresent(CaptionAnchor.self, forKey: .captionAnchor)
        // Projects saved before the picker existed were all Reels-shaped.
        frameFormat = try c.decodeIfPresent(String.self, forKey: .frameFormat) ?? FrameFormat.default.id
    }

    var stylePreset: SubtitleStylePreset { SubtitleStylePreset(rawValue: subtitleStyle) ?? .default }

    var format: FrameFormat { FrameFormat.named(frameFormat) }

    /// The pixel size the preview is framed for and the export is written at.
    var renderSize: CGSize { format.renderSize }

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Where each clip starts on the timeline, by index.
    var clipStarts: [Double] {
        var starts: [Double] = []
        var t = 0.0
        for clip in clips {
            starts.append(t)
            t += clip.duration
        }
        return starts
    }

    func start(of clipID: UUID) -> Double? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return clipStarts[index]
    }

    /// The clip under a timeline instant, plus the source second it maps to.
    /// The instant at the very end of the video belongs to the last clip.
    func locate(_ time: Double) -> (index: Int, sourceTime: Double)? {
        guard !clips.isEmpty else { return nil }
        var t = 0.0
        for (index, clip) in clips.enumerated() {
            if time < t + clip.duration || index == clips.count - 1 {
                let local = min(max(time - t, 0), clip.duration)
                return (index, clip.inPoint + local)
            }
            t += clip.duration
        }
        return nil
    }

    /// Every caption in timeline seconds, in order.
    var timelineCues: [TimelineCue] {
        var out: [TimelineCue] = []
        for (clip, start) in zip(clips, clipStarts) {
            for cue in clip.cues where cue.end > clip.inPoint && cue.start < clip.outPoint {
                let s = max(cue.start, clip.inPoint) - clip.inPoint + start
                let e = min(cue.end, clip.outPoint) - clip.inPoint + start
                if e - s > 0.01 {
                    out.append(TimelineCue(id: cue.id, start: s, end: e, text: cue.text, translation: cue.translation, anchor: cue.anchor))
                }
            }
        }
        return out
    }

    func cue(at time: Double) -> TimelineCue? {
        timelineCues.first { time >= $0.start && time < $0.end }
    }

    /// When each word of a subtitle starts, in timeline seconds: the
    /// recogniser's timings when they line up with the words on the line,
    /// otherwise spread evenly across the cue (a line that's been edited).
    func wordStarts(for cue: TimelineCue) -> [Double] {
        let count = cue.text.split(whereSeparator: { $0 == " " }).count
        guard count > 0 else { return [] }
        let even = (0..<count).map { cue.start + (cue.end - cue.start) * Double($0) / Double(count) }
        for (clip, start) in zip(clips, clipStarts) {
            guard let source = clip.cues.first(where: { $0.id == cue.id }) else { continue }
            let heard = (transcripts[clip.source.path] ?? []).filter { $0.start >= source.start - 0.01 && $0.start < source.end }
            guard heard.count == count else { return even }
            return heard.map { min(cue.end, max(cue.start, $0.start - clip.inPoint + start)) }
        }
        return even
    }

    /// Which word of `cue` is being spoken at `time`.
    func wordIndex(in cue: TimelineCue, at time: Double) -> Int {
        max(0, wordStarts(for: cue).lastIndex { $0 <= time } ?? 0)
    }

    // MARK: Edits

    mutating func append(_ clip: EditClip) { clips.append(clip) }

    mutating func remove(_ clipID: UUID) { clips.removeAll { $0.id == clipID } }

    /// Swap a clip with its neighbour. `offset` is -1 (earlier) or +1 (later).
    @discardableResult
    mutating func move(_ clipID: UUID, by offset: Int) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return false }
        let target = index + offset
        guard clips.indices.contains(target) else { return false }
        clips.swapAt(index, target)
        return true
    }

    /// Cut the clip under `time` into two at that instant. Captions go with
    /// the half where they start; one that straddles the cut is clipped to
    /// the first half so nothing shows twice.
    @discardableResult
    mutating func split(at time: Double) -> Bool {
        guard let (index, sourceTime) = locate(time) else { return false }
        var first = clips[index]
        guard sourceTime - first.inPoint >= Self.minimumClipDuration,
              first.outPoint - sourceTime >= Self.minimumClipDuration else { return false }
        var second = first
        second.id = UUID()
        second.inPoint = sourceTime
        first.outPoint = sourceTime
        first.cues = first.cues.filter { $0.start < sourceTime }.map { cue in
            var c = cue
            c.end = min(c.end, sourceTime)
            return c
        }
        second.cues = second.cues.filter { $0.start >= sourceTime }.map { cue in
            var c = cue
            c.id = UUID()
            return c
        }
        clips.replaceSubrange(index...index, with: [first, second])
        return true
    }

    /// True when the clip at `index` and the one after it are two halves of
    /// the same footage lying back to back — a split, or a trim that met its
    /// neighbour — so joining them loses nothing.
    func canRejoin(after index: Int) -> Bool {
        guard clips.indices.contains(index), clips.indices.contains(index + 1) else { return false }
        let a = clips[index], b = clips[index + 1]
        return a.source == b.source && abs(a.outPoint - b.inPoint) < 0.001
    }

    /// Merge the clip at `index` with the one after it back into one clip.
    /// The first clip keeps its identity; captions from both come along.
    /// The second's zoom is dropped in favour of the first's.
    @discardableResult
    mutating func rejoin(after index: Int) -> Bool {
        guard canRejoin(after: index) else { return false }
        var joined = clips[index]
        let tail = clips[index + 1]
        joined.outPoint = tail.outPoint
        joined.cues = (joined.cues + tail.cues).sorted { $0.start < $1.start }
        clips.replaceSubrange(index...(index + 1), with: [joined])
        return true
    }

    /// Drop everything in the clip under `time` before that instant.
    @discardableResult
    mutating func trimStart(at time: Double) -> Bool {
        guard let (index, sourceTime) = locate(time) else { return false }
        guard clips[index].outPoint - sourceTime >= Self.minimumClipDuration,
              sourceTime > clips[index].inPoint else { return false }
        clips[index].inPoint = sourceTime
        clips[index].cues.removeAll { $0.end <= sourceTime }
        return true
    }

    /// Drop everything in the clip under `time` after that instant.
    @discardableResult
    mutating func trimEnd(at time: Double) -> Bool {
        guard let (index, sourceTime) = locate(time) else { return false }
        guard sourceTime - clips[index].inPoint >= Self.minimumClipDuration,
              sourceTime < clips[index].outPoint else { return false }
        clips[index].outPoint = sourceTime
        clips[index].cues.removeAll { $0.start >= sourceTime }
        return true
    }

    /// Slide a clip's in point by `delta` source seconds (negative = earlier,
    /// revealing footage; positive = later, hiding it). Clamped so the clip
    /// keeps its minimum length and stays inside the source.
    @discardableResult
    mutating func nudgeStart(_ clipID: UUID, by delta: Double) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return false }
        let target = min(max(0, clips[i].inPoint + delta), clips[i].outPoint - Self.minimumClipDuration)
        guard abs(target - clips[i].inPoint) > 0.0001 else { return false }
        clips[i].inPoint = target
        clips[i].cues.removeAll { $0.end <= target }
        return true
    }

    /// Slide a clip's out point by `delta` source seconds.
    @discardableResult
    mutating func nudgeEnd(_ clipID: UUID, by delta: Double) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return false }
        let target = max(min(clips[i].sourceDuration, clips[i].outPoint + delta), clips[i].inPoint + Self.minimumClipDuration)
        guard abs(target - clips[i].outPoint) > 0.0001 else { return false }
        clips[i].outPoint = target
        clips[i].cues.removeAll { $0.start >= target }
        return true
    }

    mutating func setZoom(_ zoom: Double, for clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].zoom = min(max(zoom, EditClip.minZoom), EditClip.maxZoom)
    }

    /// Where the picture sits; the caller keeps it within `VideoExporter.panLimit`.
    mutating func setPan(x: Double, y: Double, for clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].panX = x
        clips[index].panY = y
    }

    mutating func setCueText(_ cueID: UUID, _ text: String) {
        for c in clips.indices {
            if let i = clips[c].cues.firstIndex(where: { $0.id == cueID }) {
                if clips[c].cues[i].text != text {
                    clips[c].cues[i].text = text
                    // The old translation no longer matches what's said.
                    clips[c].cues[i].translation = nil
                }
                return
            }
        }
    }

    mutating func setCueTranslation(_ cueID: UUID, _ text: String?) {
        for c in clips.indices {
            if let i = clips[c].cues.firstIndex(where: { $0.id == cueID }) {
                clips[c].cues[i].translation = text
                return
            }
        }
    }

    /// A detached line's own spot on the video, or nil to follow the rest.
    mutating func setCueAnchor(_ cueID: UUID, _ anchor: CaptionAnchor?) {
        for c in clips.indices {
            if let i = clips[c].cues.firstIndex(where: { $0.id == cueID }) {
                clips[c].cues[i].anchor = anchor
                return
            }
        }
    }

    /// Move a line's start and end, given in timeline seconds. Kept inside
    /// its clip and at least a tenth of a second long.
    mutating func setCueTiming(_ cueID: UUID, start: Double, end: Double) {
        for (c, clipStart) in zip(clips.indices, clipStarts) {
            guard let i = clips[c].cues.firstIndex(where: { $0.id == cueID }) else { continue }
            let clip = clips[c]
            let toSource = { (t: Double) in min(max(t - clipStart + clip.inPoint, clip.inPoint), clip.outPoint) }
            let s = toSource(start)
            let e = max(toSource(end), min(s + 0.1, clip.outPoint))
            clips[c].cues[i].start = s
            clips[c].cues[i].end = max(e, s + 0.05)
            return
        }
    }

    mutating func removeCue(_ cueID: UUID) {
        for c in clips.indices { clips[c].cues.removeAll { $0.id == cueID } }
    }

    /// A blank line starting at `time` (timeline seconds), for the user to
    /// type: it runs to the next line in the clip, the clip's end or two
    /// seconds, whichever comes first. Nil when a line already covers that
    /// moment or the gap is too small for one. Returns the new line's id.
    @discardableResult
    mutating func addCue(at time: Double) -> UUID? {
        guard let (index, sourceTime) = locate(time) else { return nil }
        let clip = clips[index]
        let start = min(sourceTime, clip.outPoint)
        guard !clip.cues.contains(where: { start >= $0.start && start < $0.end }) else { return nil }
        let nextStart = clip.cues.map(\.start).filter { $0 > start }.min() ?? clip.outPoint
        let end = min(nextStart, clip.outPoint, start + 2)
        guard end - start >= Self.minimumClipDuration else { return nil }
        let cue = CaptionCue(start: start, end: end, text: "")
        let at = clip.cues.firstIndex { $0.start > start } ?? clip.cues.count
        clips[index].cues.insert(cue, at: at)
        return cue.id
    }

    // MARK: Translation

    /// Cues on the timeline that still need a translated line.
    var untranslatedCues: [TimelineCue] {
        timelineCues.filter { $0.translation == nil && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Store translated lines, keyed by cue id.
    mutating func setTranslations(_ translations: [UUID: String]) {
        for c in clips.indices {
            for i in clips[c].cues.indices {
                if let t = translations[clips[c].cues[i].id] { clips[c].cues[i].translation = t }
            }
        }
    }

    mutating func clearTranslations() {
        for c in clips.indices {
            for i in clips[c].cues.indices { clips[c].cues[i].translation = nil }
        }
    }

    /// Replace a clip's captions with cues built from what was heard in its
    /// source. Words outside the clip's in/out range are kept too — they
    /// come into play if the clip is later trimmed back out.
    mutating func setCaptions(for clipID: UUID, words: [SpokenWord]) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].cues = CaptionBuilder.cues(from: words)
    }

    /// Captions for every clip whose source has been transcribed.
    mutating func recaptionAll() {
        for clip in clips {
            if let words = transcripts[clip.source.path] { setCaptions(for: clip.id, words: words) }
        }
    }

    /// Source files that still need listening to. A transcript with no
    /// actual words in it doesn't count as heard: a silent take is cheap to
    /// listen to again, and it's what a stopped pass could leave behind.
    var untranscribedSources: [URL] {
        var seen = Set<String>()
        return clips.compactMap { clip in
            guard !isTranscribed(clip.source), !seen.contains(clip.source.path) else { return nil }
            seen.insert(clip.source.path)
            return clip.source
        }
    }

    func isTranscribed(_ source: URL) -> Bool {
        guard let words = transcripts[source.path] else { return false }
        return words.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Transcript

    /// The captions as one paragraph — for a description, a portfolio note,
    /// or a second look at what was said.
    var transcript: String {
        timelineCues.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// SubRip subtitles, the format every editor and platform accepts. A
    /// translated line, if any, sits under the original.
    var srt: String {
        timelineCues.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))\n\(cue.displayText)\n"
        }.joined(separator: "\n")
    }

    static func srtTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total / 3600)
        let m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60))
        let ms = Int((total - floor(total)) * 1000 + 0.5) % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: Disk

    static let fileName = "project.json"

    func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func load(from folder: URL) throws -> VideoProject {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoProject.self, from: data)
    }
}

/// Turns a run of timed words into short-form captions: a few words at a
/// time, never lingering, broken at pauses so a caption doesn't bridge two
/// thoughts.
enum CaptionBuilder {
    static let maxWordsPerCue = 4
    static let maxCueDuration = 2.4
    /// A silence this long between words ends the caption.
    static let pauseBreak = 0.6
    /// A caption stays up a touch after its last word so it doesn't blink
    /// off mid-syllable — unless the next word is already coming.
    static let tail = 0.25
    static let minCueDuration = 0.5

    static func cues(from words: [SpokenWord]) -> [CaptionCue] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !words.isEmpty else { return [] }
        var groups: [[SpokenWord]] = []
        var current: [SpokenWord] = []
        for word in words {
            if let last = current.last {
                let gap = word.start - last.end
                let span = word.end - current[0].start
                if current.count >= maxWordsPerCue || gap > pauseBreak || span > maxCueDuration {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        var cues: [CaptionCue] = []
        for (index, group) in groups.enumerated() {
            let start = group[0].start
            var end = max(group[group.count - 1].end + tail, start + minCueDuration)
            if index + 1 < groups.count { end = min(end, groups[index + 1][0].start) }
            end = max(end, start + 0.05)
            cues.append(CaptionCue(start: start, end: end, text: group.map(\.text).joined(separator: " ")))
        }
        return cues
    }
}
