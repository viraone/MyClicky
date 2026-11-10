import XCTest
@testable import MyClicky

final class DocumentaryTimelineMediaTests: XCTestCase {
    func testNormalizedPeaks() {
        let peaks1 = DocumentaryTimelineMedia.normalizedPeaks(samples: [0, 100, -200, 50, 400, -100], buckets: 3)
        XCTAssertEqual(peaks1.count, 3)
        XCTAssertEqual(peaks1[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(peaks1[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(peaks1[2], 1.0, accuracy: 1e-6)

        let peaks2 = DocumentaryTimelineMedia.normalizedPeaks(samples: [10, -20, 30, -40, 50], buckets: 2)
        XCTAssertEqual(peaks2.count, 2)
        XCTAssertEqual(peaks2[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(peaks2[1], 1.0, accuracy: 1e-6)

        let peaks3 = DocumentaryTimelineMedia.normalizedPeaks(samples: [0, 0, 0], buckets: 3)
        XCTAssertEqual(peaks3.count, 3)
        XCTAssertEqual(peaks3[0], 0, accuracy: 1e-6)
        XCTAssertEqual(peaks3[1], 0, accuracy: 1e-6)
        XCTAssertEqual(peaks3[2], 0, accuracy: 1e-6)

        XCTAssertEqual(DocumentaryTimelineMedia.normalizedPeaks(samples: [], buckets: 4), [])
        XCTAssertEqual(DocumentaryTimelineMedia.normalizedPeaks(samples: [1, 2], buckets: 0), [])

        let peaks4 = DocumentaryTimelineMedia.normalizedPeaks(samples: [Int16.min, 0], buckets: 2)
        XCTAssertEqual(peaks4.count, 2)
        XCTAssertEqual(peaks4[0], 1, accuracy: 1e-6)
        XCTAssertEqual(peaks4[1], 0, accuracy: 1e-6)
    }

    func testThumbnailTimes() {
        let times = DocumentaryTimelineMedia.thumbnailTimes(duration: 50, count: 5)
        XCTAssertEqual(times.count, 5)
        XCTAssertEqual(times[0], 5, accuracy: 1e-6)
        XCTAssertEqual(times[1], 15, accuracy: 1e-6)
        XCTAssertEqual(times[2], 25, accuracy: 1e-6)
        XCTAssertEqual(times[3], 35, accuracy: 1e-6)
        XCTAssertEqual(times[4], 45, accuracy: 1e-6)

        XCTAssertEqual(DocumentaryTimelineMedia.thumbnailTimes(duration: 0, count: 5), [])
        XCTAssertEqual(DocumentaryTimelineMedia.thumbnailTimes(duration: 10, count: 0), [])
    }
}
