import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class ClaudeDesktopTalkTests: XCTestCase {
    private func mic(_ label: String, x: CGFloat, minY: CGFloat) -> ClaudeDesktopTalk.MicCandidate {
        .init(label: label, frame: NSRect(x: x, y: minY, width: 44, height: 45))
    }

    // MARK: - Recognising the mic description

    func testMicDescriptionsAreRecognised() {
        XCTAssertTrue(ClaudeDesktopTalk.isMicDescription("Press and hold to record"))
        XCTAssertTrue(ClaudeDesktopTalk.isMicDescription("Stop recording"))
        XCTAssertTrue(ClaudeDesktopTalk.isMicDescription("Start dictation"))
    }

    func testNonMicDescriptionsAreRejected() {
        XCTAssertFalse(ClaudeDesktopTalk.isMicDescription("Stop"))
        XCTAssertFalse(ClaudeDesktopTalk.isMicDescription("Send"))
        XCTAssertFalse(ClaudeDesktopTalk.isMicDescription(""))
        XCTAssertFalse(ClaudeDesktopTalk.isMicDescription("Lao voice support for Claude"))
    }

    // MARK: - Picking the mic button

    func testNoCandidatesMeansNoMic() {
        XCTAssertNil(ClaudeDesktopTalk.pickMicButton([]))
    }

    func testOnlyNonMicCandidatesMeansNoMic() {
        XCTAssertNil(ClaudeDesktopTalk.pickMicButton([mic("Stop", x: 100, minY: 100)]))
    }

    func testLowestMicWins() {
        let a = mic("Press and hold to record", x: 100, minY: 500)
        let b = mic("Press and hold to record", x: 1641, minY: 100)
        XCTAssertEqual(ClaudeDesktopTalk.pickMicButton([a, b]), b)
    }

    func testTieOnMinYBreaksByLargestMidX() {
        let a = mic("Press and hold to record", x: 100, minY: 100)
        let b = mic("Press and hold to record", x: 1641, minY: 100)
        XCTAssertEqual(ClaudeDesktopTalk.pickMicButton([a, b]), b)
    }

    func testNonMicCandidateLowerOnScreenIsIgnored() {
        let nonMic = mic("Stop", x: 100, minY: 10)
        let realMic = mic("Press and hold to record", x: 1641, minY: 500)
        XCTAssertEqual(ClaudeDesktopTalk.pickMicButton([nonMic, realMic]), realMic)
    }
}

