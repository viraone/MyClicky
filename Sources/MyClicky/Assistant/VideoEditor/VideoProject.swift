import Foundation

/// One caption on screen. Times are in the *source clip's* seconds, so a
/// cue rides along with its clip when the clip is moved, split or trimmed;
/// `VideoProject.timelineCues` maps them onto the finished video.
struct CaptionCue: Codable, Equatable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
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

    static let minZoom = 1.0
    static let maxZoom = 4.0

    init(id: UUID = UUID(), source: URL, sourceDuration: Double, inPoint: Double = 0, outPoint: Double? = nil, cues: [CaptionCue] = [], zoom: Double = 1) {
        self.id = id
        self.source = source
        self.sourceDuration = sourceDuration
        self.inPoint = inPoint
        self.outPoint = outPoint ?? sourceDuration
        self.cues = cues
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey { case id, source, sourceDuration, inPoint, outPoint, cues, zoom }

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
}

/// Everything the editor needs to rebuild a video: an ordered list of clips
/// plus their captions. Saved as `project.json` in the project folder.
struct VideoProject: Codable, Equatable {
    static let currentVersion = 1
    /// The shortest clip the editor will make — a split or trim closer than
    /// this to an edge is refused rather than leaving a sliver.
    static let minimumClipDuration = 0.1

    var version = VideoProject.currentVersion
    var name: String
    var clips: [EditClip]
    var created: Date
    /// Every word heard in each source file, by path, so re-captioning
    /// after a split or trim doesn't listen to the whole take again.
    var transcripts: [String: [SpokenWord]]

    init(name: String, clips: [EditClip] = [], created: Date = Date(), transcripts: [String: [SpokenWord]] = [:]) {
        self.name = name
        self.clips = clips
        self.created = created
        self.transcripts = transcripts
    }

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
                    out.append(TimelineCue(id: cue.id, start: s, end: e, text: cue.text))
                }
            }
        }
        return out
    }

    func cue(at time: Double) -> TimelineCue? {
        timelineCues.first { time >= $0.start && time < $0.end }
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

    mutating func setCueText(_ cueID: UUID, _ text: String) {
        for c in clips.indices {
            if let i = clips[c].cues.firstIndex(where: { $0.id == cueID }) {
                clips[c].cues[i].text = text
                return
            }
        }
    }

    mutating func removeCue(_ cueID: UUID) {
        for c in clips.indices { clips[c].cues.removeAll { $0.id == cueID } }
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

    /// Source files that still need listening to.
    var untranscribedSources: [URL] {
        var seen = Set<String>()
        return clips.compactMap { clip in
            guard transcripts[clip.source.path] == nil, !seen.contains(clip.source.path) else { return nil }
            seen.insert(clip.source.path)
            return clip.source
        }
    }

    // MARK: Transcript

    /// The captions as one paragraph — for a description, a portfolio note,
    /// or a second look at what was said.
    var transcript: String {
        timelineCues.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// SubRip subtitles, the format every editor and platform accepts.
    var srt: String {
        timelineCues.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))\n\(cue.text)\n"
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
