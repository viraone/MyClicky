import XCTest
@testable import MyClicky

final class DocumentaryTimelineTests: XCTestCase {
    func testMajorStep() {
        XCTAssertEqual(DocumentaryTimelineMath.majorStep(pxPerSec: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.majorStep(pxPerSec: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.majorStep(pxPerSec: 1000), 0.1, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.majorStep(pxPerSec: 0.1), 300, accuracy: 1e-9)
    }

    func testMinorStep() {
        XCTAssertEqual(DocumentaryTimelineMath.minorStep(major: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.minorStep(major: 0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.minorStep(major: 10), 2.5, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.minorStep(major: 0.1), 0.05, accuracy: 1e-9)
    }

    func testFitZoom() {
        XCTAssertEqual(DocumentaryTimelineMath.fitZoom(viewWidth: 880, duration: 50), 16, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.fitZoom(viewWidth: 100, duration: 500), 2, accuracy: 1e-9)
    }

    func testContentWidth() {
        XCTAssertEqual(DocumentaryTimelineMath.contentWidth(viewWidth: 800, duration: 51, pxPerSec: 10), 800, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.contentWidth(viewWidth: 800, duration: 51, pxPerSec: 20), 1180, accuracy: 1e-9)
    }

    func testTime() {
        XCTAssertEqual(DocumentaryTimelineMath.time(atX: 320, pxPerSec: 16, duration: 50), 20, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.time(atX: -5, pxPerSec: 16, duration: 50), 0, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.time(atX: 2000, pxPerSec: 16, duration: 50), 50, accuracy: 1e-9)
    }

    func testClipWidth() {
        XCTAssertEqual(DocumentaryTimelineMath.clipWidth(start: 0, end: 0.1, pxPerSec: 10), 6, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.clipWidth(start: 10, end: 20, pxPerSec: 16), 160, accuracy: 1e-9)
    }

    func testRulerLabel() {
        XCTAssertEqual(DocumentaryTimelineMath.rulerLabel(5, major: 1), "5s")
        XCTAssertEqual(DocumentaryTimelineMath.rulerLabel(0.5, major: 0.5), "0.5s")
        XCTAssertEqual(DocumentaryTimelineMath.rulerLabel(75, major: 15), "1:15")
        XCTAssertEqual(DocumentaryTimelineMath.rulerLabel(60, major: 60), "1:00")
        XCTAssertEqual(DocumentaryTimelineMath.rulerLabel(7.4, major: 1), "7s")
    }

    func testActiveIndex() {
        let ranges: [(start: Double, end: Double)] = [(0, 5), (5, 12)]
        XCTAssertEqual(DocumentaryTimelineMath.activeIndex(ranges: ranges, at: 5), 1)
        XCTAssertEqual(DocumentaryTimelineMath.activeIndex(ranges: ranges, at: 4.99), 0)
        XCTAssertNil(DocumentaryTimelineMath.activeIndex(ranges: ranges, at: 12))
        XCTAssertNil(DocumentaryTimelineMath.activeIndex(ranges: ranges, at: -1))
    }

    func testClampZoom() {
        XCTAssertEqual(DocumentaryTimelineMath.clampZoom(1), 2, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.clampZoom(1000), 400, accuracy: 1e-9)
        XCTAssertEqual(DocumentaryTimelineMath.clampZoom(16), 16, accuracy: 1e-9)
    }
}
