import AVFoundation
import XCTest
@testable import MyClicky

final class VideoProjectTests: XCTestCase {
    func testClipWithoutZoomKeyDecodesToOne() throws {
        let json = """
        {"id":"\(UUID().uuidString)","source":"file:///tmp/a.mov","sourceDuration":10,"inPoint":0,"outPoint":10,"cues":[]}
        """.data(using: .utf8)!
        let clip = try JSONDecoder().decode(EditClip.self, from: json)
        XCTAssertEqual(clip.zoom, 1)
    }

    func testSetZoomClamps() throws {
        var project = VideoProject(name: "z")
        let clip = EditClip(source: URL(fileURLWithPath: "/tmp/a.mov"), sourceDuration: 10)
        project.clips = [clip]
        project.setZoom(99, for: clip.id)
        XCTAssertEqual(project.clips[0].zoom, EditClip.maxZoom)
        project.setZoom(0.2, for: clip.id)
        XCTAssertEqual(project.clips[0].zoom, EditClip.minZoom)
    }

    private func clip(_ name: String, duration: Double, cues: [CaptionCue] = []) -> EditClip {
        EditClip(source: URL(fileURLWithPath: "/tmp/\(name).mov"), sourceDuration: duration, cues: cues)
    }

    func testClipsLayEndToEndAndLocateMapsIntoSourceTime() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 10))
        var b = clip("b", duration: 20)
        b.inPoint = 5
        b.outPoint = 12
        project.append(b)

        XCTAssertEqual(project.duration, 17)
        XCTAssertEqual(project.clipStarts, [0, 10])
        XCTAssertEqual(project.locate(3)?.index, 0)
        XCTAssertEqual(project.locate(3)?.sourceTime, 3)
        XCTAssertEqual(project.locate(12)?.index, 1)
        XCTAssertEqual(project.locate(12)?.sourceTime ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(project.locate(17)?.index, 1, "the very end belongs to the last clip")
        XCTAssertEqual(project.locate(17)?.sourceTime ?? 0, 12, accuracy: 1e-9)
    }

    func testSplitDividesTheClipAndItsCaptions() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 10, cues: [
            CaptionCue(start: 1, end: 2, text: "one"),
            CaptionCue(start: 3.5, end: 5.5, text: "straddles"),
            CaptionCue(start: 7, end: 8, text: "late"),
        ]))
        XCTAssertTrue(project.split(at: 4))
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertEqual(project.clips[0].outPoint, 4)
        XCTAssertEqual(project.clips[1].inPoint, 4)
        XCTAssertEqual(project.clips[0].cues.map(\.text), ["one", "straddles"])
        XCTAssertEqual(project.clips[0].cues[1].end, 4, "a straddling caption is cut at the split")
        XCTAssertEqual(project.clips[1].cues.map(\.text), ["late"])
        XCTAssertEqual(project.duration, 10)
        XCTAssertEqual(project.timelineCues.map(\.text), ["one", "straddles", "late"])

        XCTAssertFalse(project.split(at: 0.02), "no slivers")
        XCTAssertFalse(project.split(at: 9.99))
    }

    func testTrimsMoveTheEdgesAndDropCaptionsOutside() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 10, cues: [
            CaptionCue(start: 1, end: 2, text: "early"),
            CaptionCue(start: 5, end: 6, text: "middle"),
            CaptionCue(start: 8, end: 9, text: "late"),
        ]))
        XCTAssertTrue(project.trimStart(at: 3))
        XCTAssertEqual(project.clips[0].inPoint, 3)
        XCTAssertEqual(project.clips[0].cues.map(\.text), ["middle", "late"])
        // Timeline time 4 is now source time 7.
        XCTAssertTrue(project.trimEnd(at: 4))
        XCTAssertEqual(project.clips[0].outPoint, 7)
        XCTAssertEqual(project.clips[0].cues.map(\.text), ["middle"])
        XCTAssertEqual(project.duration, 4)
        XCTAssertEqual(project.timelineCues.first?.start ?? -1, 2, accuracy: 1e-9,
                       "captions shift with the new in point")
    }

    func testMoveSwapsNeighboursAndCarriesCaptions() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 4, cues: [CaptionCue(start: 0, end: 1, text: "A")]))
        project.append(clip("b", duration: 6, cues: [CaptionCue(start: 0, end: 1, text: "B")]))
        let b = project.clips[1].id
        XCTAssertTrue(project.move(b, by: -1))
        XCTAssertEqual(project.clips.map(\.name), ["b", "a"])
        XCTAssertEqual(project.timelineCues.map { "\($0.text)@\($0.start)" }, ["B@0.0", "A@6.0"])
        XCTAssertFalse(project.move(b, by: -1), "already first")
    }

    func testCueEditsAndRemoval() {
        var project = VideoProject(name: "t")
        let cue = CaptionCue(start: 0, end: 1, text: "teh")
        project.append(clip("a", duration: 4, cues: [cue]))
        project.setCueText(cue.id, "the")
        XCTAssertEqual(project.clips[0].cues[0].text, "the")
        project.removeCue(cue.id)
        XCTAssertTrue(project.clips[0].cues.isEmpty)
    }

    func testTranscriptsAreSharedAcrossSplitClips() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 10))
        XCTAssertEqual(project.untranscribedSources.map(\.lastPathComponent), ["a.mov"])
        project.transcripts["/tmp/a.mov"] = [
            SpokenWord(text: "hello", start: 1, end: 1.4),
            SpokenWord(text: "there", start: 1.5, end: 1.9),
            SpokenWord(text: "again", start: 6, end: 6.4),
        ]
        XCTAssertTrue(project.untranscribedSources.isEmpty)
        XCTAssertTrue(project.split(at: 4))
        project.recaptionAll()
        XCTAssertEqual(project.clips[0].cues.map(\.text), ["hello there", "again"],
                       "every clip carries the whole take's words; the timeline shows only its own")
        XCTAssertEqual(project.timelineCues.map(\.text), ["hello there", "again"])
        XCTAssertEqual(project.timelineCues[1].start, 6, accuracy: 1e-9)
        // Every split piece already knows its words, so nothing is re-heard.
        XCTAssertTrue(project.untranscribedSources.isEmpty)
    }

    func testSRTAndTranscript() {
        var project = VideoProject(name: "t")
        project.append(clip("a", duration: 70, cues: [
            CaptionCue(start: 0.5, end: 2, text: "Hi there"),
            CaptionCue(start: 61.25, end: 62, text: "later"),
        ]))
        XCTAssertEqual(project.srt, """
        1
        00:00:00,500 --> 00:00:02,000
        Hi there

        2
        00:01:01,250 --> 00:01:02,000
        later

        """)
        XCTAssertEqual(project.transcript, "Hi there later")
        XCTAssertEqual(VideoProject.srtTime(3661.5), "01:01:01,500")
        XCTAssertEqual(VideoProject.srtTime(-2), "00:00:00,000")
    }

    func testSaveAndLoadRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoProjectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = VideoProject(name: "Round trip")
        project.append(clip("a", duration: 10, cues: [CaptionCue(start: 1, end: 2, text: "one")]))
        project.transcripts["/tmp/a.mov"] = [SpokenWord(text: "one", start: 1, end: 1.5)]
        try project.save(to: folder)
        let loaded = try VideoProject.load(from: folder)
        XCTAssertEqual(loaded.name, project.name)
        XCTAssertEqual(loaded.clips, project.clips)
        XCTAssertEqual(loaded.transcripts, project.transcripts)
        XCTAssertEqual(loaded.version, VideoProject.currentVersion)
    }
}

final class CaptionBuilderTests: XCTestCase {
    private func words(_ pairs: [(String, Double, Double)]) -> [SpokenWord] {
        pairs.map { SpokenWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    func testGroupsAFewWordsAtATime() {
        let cues = CaptionBuilder.cues(from: words([
            ("this", 0, 0.2), ("is", 0.25, 0.4), ("a", 0.45, 0.5), ("quick", 0.55, 0.8),
            ("little", 0.85, 1.1), ("demo", 1.15, 1.5),
        ]))
        XCTAssertEqual(cues.map(\.text), ["this is a quick", "little demo"])
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 0.85, "held to the next caption, not beyond it")
        XCTAssertEqual(cues[1].end, 1.75, accuracy: 1e-9, "the last caption gets its tail")
    }

    func testAPauseEndsTheCaption() {
        let cues = CaptionBuilder.cues(from: words([
            ("okay", 0, 0.3), ("so", 1.5, 1.7), ("here", 1.75, 2.0),
        ]))
        XCTAssertEqual(cues.map(\.text), ["okay", "so here"])
        XCTAssertEqual(cues[0].end, 0.55, accuracy: 1e-9)
    }

    func testALongSpanEndsTheCaption() {
        let cues = CaptionBuilder.cues(from: words([
            ("sloooow", 0, 1.5), ("words", 1.6, 3.0), ("here", 3.1, 3.4),
        ]))
        XCTAssertEqual(cues.map(\.text), ["sloooow", "words here"])
    }

    func testEmptyAndBlankWords() {
        XCTAssertTrue(CaptionBuilder.cues(from: []).isEmpty)
        XCTAssertEqual(CaptionBuilder.cues(from: words([(" ", 0, 1), ("hi", 1, 1.2)])).map(\.text), ["hi"])
        let lone = CaptionBuilder.cues(from: words([("hi", 1, 1.2)]))
        XCTAssertEqual(lone[0].end, 1.5, "a single short word stays up long enough to read")
    }
}

final class VideoExporterGeometryTests: XCTestCase {
    func testFillZoomForLandscapeCoversPortraitFrame() {
        let zoom = VideoExporter.fillZoom(naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: .identity)
        XCTAssertEqual(zoom, (1920.0 / 1080.0) / (1080.0 / 1920.0), accuracy: 0.001)
    }

    func testFillZoomForPortraitIsOne() {
        XCTAssertEqual(VideoExporter.fillZoom(naturalSize: CGSize(width: 1080, height: 1920), preferredTransform: .identity), 1, accuracy: 0.0001)
    }

    func testZoomScalesAroundCentre() {
        let render = VideoExporter.renderSize
        let plain = VideoExporter.fitTransform(naturalSize: CGSize(width: 1080, height: 1920), preferredTransform: .identity, zoom: 1, into: render)
        let zoomed = VideoExporter.fitTransform(naturalSize: CGSize(width: 1080, height: 1920), preferredTransform: .identity, zoom: 2, into: render)
        let centre = CGPoint(x: 540, y: 960)
        XCTAssertEqual(centre.applying(plain).x, centre.applying(zoomed).x, accuracy: 0.5)
        XCTAssertEqual(centre.applying(plain).y, centre.applying(zoomed).y, accuracy: 0.5)
        XCTAssertEqual(zoomed.a, plain.a * 2, accuracy: 0.0001)
    }

    private func apply(_ t: CGAffineTransform, to size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).applying(t).standardized
    }

    func testPortraitSourceFillsTheFrame() {
        let t = VideoExporter.fitTransform(naturalSize: CGSize(width: 2160, height: 3840), preferredTransform: .identity)
        let r = apply(t, to: CGSize(width: 2160, height: 3840))
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.minY, 0, accuracy: 0.01)
        XCTAssertEqual(r.width, 1080, accuracy: 0.01)
        XCTAssertEqual(r.height, 1920, accuracy: 0.01)
    }

    func testRotatedPhoneVideoIsUprightAndFilling() {
        // iPhone portrait footage: landscape pixels with a 90° preferred transform.
        let natural = CGSize(width: 3840, height: 2160)
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        let t = VideoExporter.fitTransform(naturalSize: natural, preferredTransform: rotate)
        let r = apply(t, to: natural)
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.minY, 0, accuracy: 0.01)
        XCTAssertEqual(r.width, 1080, accuracy: 0.01)
        XCTAssertEqual(r.height, 1920, accuracy: 0.01)
    }

    func testWidescreenScreenRecordingIsLetterboxedInTheMiddle() {
        let natural = CGSize(width: 3456, height: 2234)
        let t = VideoExporter.fitTransform(naturalSize: natural, preferredTransform: .identity)
        let r = apply(t, to: natural)
        XCTAssertEqual(r.width, 1080, accuracy: 0.01)
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.midY, 960, accuracy: 0.01, "centred vertically")
        XCTAssertLessThan(r.height, 1920)
    }

    func testCaptionSitsCentredInTheLowerThirdInsideTheSafeWidth() {
        let style = CaptionStyle()
        let (pill, textSize) = VideoExporter.captionFrame(for: "fix any wording below", style: style)
        XCTAssertEqual(pill.midX, 540, accuracy: 1)
        XCTAssertEqual(pill.midY, 1920 * 0.30, accuracy: 1)
        XCTAssertLessThanOrEqual(pill.width, 1080 * style.maxWidthShare + 1)
        XCTAssertGreaterThan(textSize.width, 0)
        XCTAssertGreaterThan(pill.height, textSize.height)
    }

    @MainActor
    func testEachCaptionLayerIsScheduledForItsOwnStretch() {
        let overlay = VideoExporter.captionOverlay(for: [
            TimelineCue(id: UUID(), start: 0, end: 1.5, text: "first"),
            TimelineCue(id: UUID(), start: 2, end: 3, text: "second"),
            TimelineCue(id: UUID(), start: 4, end: 4, text: "zero length"),
            TimelineCue(id: UUID(), start: 5, end: 6, text: "   "),
        ], style: CaptionStyle())
        let layers = overlay.sublayers ?? []
        XCTAssertEqual(layers.count, 2, "empty and zero-length captions draw nothing")
        XCTAssertEqual(layers[0].opacity, 0, "hidden until its animation shows it")
        let first = layers[0].animation(forKey: "visible") as? CABasicAnimation
        let second = layers[1].animation(forKey: "visible") as? CABasicAnimation
        XCTAssertEqual(first?.beginTime, AVCoreAnimationBeginTimeAtZero)
        XCTAssertEqual(first?.duration ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(second?.beginTime ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(second?.duration ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(second?.isRemovedOnCompletion, false)
    }
}

@MainActor
final class VideoEditorModelTests: XCTestCase {
    func testFolderNamesAreSafeAndUnique() {
        XCTAssertEqual(VideoEditorModel.folderName(for: "  Notion: review / take 2  ", existing: { _ in false }), "Notion- review - take 2")
        XCTAssertEqual(VideoEditorModel.folderName(for: "", existing: { _ in false }), "Untitled")
        var taken: Set<String> = ["Demo", "Demo 2"]
        XCTAssertEqual(VideoEditorModel.folderName(for: "Demo", existing: { taken.contains($0) }), "Demo 3")
        taken.insert("Demo 3")
        XCTAssertEqual(VideoEditorModel.folderName(for: "Demo", existing: { taken.contains($0) }), "Demo 4")
    }

    func testClockFormatting() {
        XCTAssertEqual(VideoEditorModel.clock(0), "0:00.00")
        XCTAssertEqual(VideoEditorModel.clock(65.5), "1:05.50")
        XCTAssertEqual(VideoEditorModel.clock(-3), "0:00.00")
    }

    func testTheVideoTabHasNoMicAndAppearsBeforeExtensions() {
        XCTAssertFalse(AssistantTab.video.takesVoice)
        XCTAssertEqual(AssistantTab.video.shortName, "Video")
        let all = AssistantTab.allCases
        XCTAssertLessThan(all.firstIndex(of: .video)!, all.firstIndex(of: .extensions)!)
    }
}

final class AudioWaveformTests: XCTestCase {
    func testNormalizedBringsTheLoudestMomentToTheTop() {
        let out = AudioWaveform.normalized([0.1, 0.4, 0.2])
        XCTAssertEqual(out[1], 1, accuracy: 1e-6)
        XCTAssertEqual(out[0], sqrt(0.25), accuracy: 1e-6, "soft knee: quiet parts stay visible")
        XCTAssertEqual(AudioWaveform.normalized([0, 0]), [0, 0], "silence stays flat")
        XCTAssertEqual(AudioWaveform.normalized([]), [])
    }

    func testBarsShowOnlyTheTrimmedStretch() {
        // 10 s source, one peak per second; the clip keeps 4–8 s.
        let peaks: [Float] = [0, 0, 0, 0, 1, 0.2, 0.2, 0.8, 0, 0]
        let bars = AudioWaveform.bars(from: peaks, sourceDuration: 10, inPoint: 4, outPoint: 8, count: 4)
        XCTAssertEqual(bars, [1, 0.2, 0.2, 0.8])
    }

    func testBarsResampleUpAndDown() {
        let peaks: [Float] = [0.1, 0.9, 0.3, 0.7]
        XCTAssertEqual(AudioWaveform.bars(from: peaks, sourceDuration: 4, inPoint: 0, outPoint: 4, count: 2), [0.9, 0.7],
                       "downsampling keeps the peak of each stretch")
        XCTAssertEqual(AudioWaveform.bars(from: peaks, sourceDuration: 4, inPoint: 0, outPoint: 4, count: 8).count, 8)
        XCTAssertEqual(AudioWaveform.bars(from: [], sourceDuration: 4, inPoint: 0, outPoint: 4, count: 8), [])
        XCTAssertEqual(AudioWaveform.bars(from: peaks, sourceDuration: 4, inPoint: 3, outPoint: 3, count: 8), [])
    }

    func testReadsPeaksFromARealFile() async throws {
        // Half a second of silence, then half a second of tone.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        // Write in its own scope so the file is closed before it's read.
        try {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames: AVAudioFrameCount = 44100
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                data[i] = i < 22050 ? 0 : 0.8 * sin(Float(i) * 2 * .pi * 440 / 44100)
            }
            try file.write(from: buffer)
        }()

        let peaks = try await AudioWaveform.peaks(for: url, buckets: 20)
        XCTAssertEqual(peaks.count, 20)
        XCTAssertLessThan(peaks[0..<8].max() ?? 1, 0.15, "the silent half is flat")
        XCTAssertGreaterThan(peaks[12..<20].min() ?? 0, 0.7, "the tone half is tall")
    }
}
