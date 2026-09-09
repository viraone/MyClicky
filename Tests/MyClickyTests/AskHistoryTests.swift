import XCTest
@testable import MyClicky

final class AskHistoryTests: XCTestCase {
    func testDayLabels() {
        let now = Date()
        XCTAssertEqual(AskHistoryStore.dayLabel(for: now, now: now), "Today")
        XCTAssertEqual(AskHistoryStore.dayLabel(for: now.addingTimeInterval(-86_400), now: now), "Yesterday")
        let old = now.addingTimeInterval(-40 * 86_400)
        XCTAssertFalse(["Today", "Yesterday"].contains(AskHistoryStore.dayLabel(for: old, now: now)))
    }

    func testEntryRoundTripsThroughJSON() throws {
        let entry = AskHistoryEntry(question: "What is this?", answer: "A test.", date: Date(), attachmentNames: ["a.png"])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode([AskHistoryEntry].self, from: enc.encode([entry]))
        XCTAssertEqual(back.first?.id, entry.id)
        XCTAssertEqual(back.first?.attachmentNames, ["a.png"])
    }
}
