import XCTest
@testable import MyClicky

final class GmailLargeMessageDedupeTests: XCTestCase {
    private func message(
        _ id: String, thread: String, size: Int64
    ) -> GmailService.LargeMessage {
        GmailService.LargeMessage(
            id: id, threadId: thread, from: "someone@example.com", subject: "Subject \(id)",
            date: nil, sizeEstimate: size, hasAttachment: true
        )
    }

    func testKeepsOnlyTheLargestMessagePerThread() {
        let messages = [
            message("a", thread: "t1", size: 1_000),
            message("b", thread: "t1", size: 5_000),
            message("c", thread: "t2", size: 3_000),
        ]
        let result = GmailService.dedupeKeepingLargest(messages)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.threadId == "t1" }?.id, "b")
        XCTAssertEqual(result.first { $0.threadId == "t2" }?.id, "c")
    }

    func testSortsBySizeDescending() {
        let messages = [
            message("a", thread: "t1", size: 1_000),
            message("b", thread: "t2", size: 9_000),
            message("c", thread: "t3", size: 5_000),
        ]
        let result = GmailService.dedupeKeepingLargest(messages)
        XCTAssertEqual(result.map(\.id), ["b", "c", "a"])
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(GmailService.dedupeKeepingLargest([]).isEmpty)
    }
}
