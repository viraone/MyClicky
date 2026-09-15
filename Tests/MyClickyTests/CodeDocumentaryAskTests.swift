import XCTest
@testable import MyClicky

@MainActor
final class CodeDocumentaryAskTests: XCTestCase {
    private let script: [String: Any] = [
        "title": "The Search Box",
        "scenes": [
            ["id": "open", "kind": "title", "narration": "Cold open."],
            ["id": "helper", "kind": "code", "heading": "The helper", "lines": [6, 19], "narration": "Derives a term."],
            ["id": "walk", "kind": "example", "heading": "Walkthrough", "narration": "Step by step."],
            ["id": "takeaways", "kind": "list", "heading": "Takeaways", "narration": "Four ideas."],
        ],
    ]

    func testExactTimelineWinsOverEstimate() {
        let chapters = CodeDocumentaryModel.buildChapters(
            script: script,
            timeline: ["open": (0, 9.5), "helper": (9.5, 31.2)],
            durations: ["open": 5, "helper": 18, "walk": 12, "takeaways": 10])
        XCTAssertEqual(chapters.count, 4)
        XCTAssertEqual(chapters[1].start, 9.5)
        XCTAssertEqual(chapters[1].end, 31.2)
        XCTAssertEqual(chapters[1].lines, 6...19)
        XCTAssertEqual(chapters[1].heading, "The helper")
        // Scenes without an exact entry continue from where the last one ended.
        XCTAssertEqual(chapters[2].start, 31.2)
        XCTAssertGreaterThan(chapters[2].end, 31.2 + 12)
        XCTAssertEqual(chapters[0].heading, "The Search Box")
        XCTAssertNil(chapters[0].lines)
    }

    func testEstimateIsMonotonic() {
        let chapters = CodeDocumentaryModel.buildChapters(
            script: script, timeline: [:], durations: ["open": 5, "helper": 18, "walk": 12, "takeaways": 10])
        for (a, b) in zip(chapters, chapters.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
            XCTAssertLessThan(a.start, a.end)
        }
    }

    func testAnswerParsingFallsBackToChapterLines() {
        let a = CodeDocumentaryModel.parseAnswer(
            ["answer": "It picks the longest word.", "verified": true, "lines": [12, 14]],
            question: "Why?", fallbackLines: 6...19, excerpt: "  12  let longest = words.max()")
        XCTAssertEqual(a.lines, 12...14)
        XCTAssertEqual(a.excerpt, "  12  let longest = words.max()")
        XCTAssertTrue(a.verified)
        XCTAssertTrue(a.steps.isEmpty)

        let b = CodeDocumentaryModel.parseAnswer(
            ["answer": "Probably.", "verified": false, "lines": NSNull(),
             "steps": ["Split the title", "Drop short words", "Sort longest first"]],
            question: "Show me", fallbackLines: 6...19)
        XCTAssertEqual(b.lines, 6...19)
        XCTAssertFalse(b.verified)
        XCTAssertEqual(b.steps.count, 3)

        let c = CodeDocumentaryModel.parseAnswer([:], question: "?", fallbackLines: nil)
        XCTAssertFalse(c.text.isEmpty)
        XCTAssertNil(c.lines)
    }

    func testRemoteStateLineWhenNothingIsShowing() {
        let model = CodeDocumentaryModel()
        let line = model.remoteStateLine()
        XCTAssertTrue(line.hasPrefix("DOC_STATE "))
        let fields = line.dropFirst(10).split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(fields[1], "NONE")
        XCTAssertEqual(fields[6], "IDLE")
    }

    func testRemoteDocCommandIsForwarded() {
        let service = RemoteControlService()
        var got: [String] = []
        service.onDocumentary = { got.append($0) }
        service.handle("DOC ASK")
        service.handle("DOC ASK_TEXT why does this exist?")
        service.handle("DOC SKIP -10")
        service.handle("DOC SEEK 42")
        XCTAssertEqual(got, ["ASK", "ASK_TEXT why does this exist?", "SKIP -10", "SEEK 42"])
    }

    func testRemoteCommandsAreIgnoredWithoutAFilm() {
        let model = CodeDocumentaryModel()
        model.handleRemote("ASK")
        model.handleRemote("ASK_TEXT anything")
        model.handleRemote("PLAYPAUSE")
        XCTAssertEqual(model.askPhase, .idle)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.nowPlaying)
    }

    func testRemoteReadoutIsOptIn() {
        let model = CodeDocumentaryModel()
        XCTAssertFalse(model.remoteReadoutEnabled)
        model.handleRemote("READOUT ON")
        XCTAssertTrue(model.remoteReadoutEnabled)
        model.handleRemote("READOUT OFF")
        XCTAssertFalse(model.remoteReadoutEnabled)
    }

    func testTimecode() {
        XCTAssertEqual(CodeDocumentaryModel.timecode(0), "0:00")
        XCTAssertEqual(CodeDocumentaryModel.timecode(134.4), "2:14")
        XCTAssertEqual(CodeDocumentaryModel.timecode(-3), "0:00")
    }

    func testVoiceActivityRejectsRoomNoiseAndAcceptsSpeech() {
        XCTAssertFalse(SpeechService.isLikelyVoice(rms: 0.002, peak: 0.01))
        XCTAssertFalse(SpeechService.isLikelyVoice(rms: 0.01, peak: 0.02))
        XCTAssertTrue(SpeechService.isLikelyVoice(rms: 0.008, peak: 0.025))
        XCTAssertTrue(SpeechService.isLikelyVoice(rms: 0.03, peak: 0.15))
    }

    func testCancelListeningClosesMicrophone() {
        let model = CodeDocumentaryModel()
        var closedMic = false
        model.onCancelMic = { closedMic = true }
        model.askPhase = .listening

        model.cancelAsk()

        XCTAssertTrue(closedMic)
        XCTAssertEqual(model.askPhase, .idle)
    }
}
