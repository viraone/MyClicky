import XCTest
@testable import MyClicky

final class DriveQuotaMathTests: XCTestCase {
    func testTargetBytesUsesFreeTierWhenUnlimited() {
        XCTAssertEqual(DriveQuotaMath.targetBytes(limit: nil), DriveQuotaMath.freeTierBytes)
    }

    func testTargetBytesCapsAPaidPlanAtTheFreeTier() {
        // A 100 GB paid plan still targets 15 GB once Google One is cancelled.
        XCTAssertEqual(DriveQuotaMath.targetBytes(limit: 100_000_000_000), DriveQuotaMath.freeTierBytes)
    }

    func testTargetBytesRespectsASmallerLimit() {
        XCTAssertEqual(DriveQuotaMath.targetBytes(limit: 5_000_000_000), 5_000_000_000)
    }

    func testProjectionStillOverAfterPartialCleanup() {
        let target = DriveQuotaMath.targetBytes(limit: nil)
        let projection = DriveQuotaMath.projection(usage: 16_620_000_000, selectedBytes: 1_000_000_000, target: target)
        XCTAssertEqual(projection.remainingBytes, 15_620_000_000)
        XCTAssertEqual(projection.overBytes, 620_000_000)
        XCTAssertFalse(projection.isUnderLimit)
    }

    func testProjectionUnderLimitAfterEnoughCleanup() {
        let target = DriveQuotaMath.targetBytes(limit: nil)
        let projection = DriveQuotaMath.projection(usage: 16_620_000_000, selectedBytes: 2_000_000_000, target: target)
        XCTAssertEqual(projection.remainingBytes, 14_620_000_000)
        XCTAssertEqual(projection.overBytes, 0)
        XCTAssertTrue(projection.isUnderLimit)
    }

    func testProjectionNeverGoesNegativeWhenSelectionExceedsUsage() {
        let target = DriveQuotaMath.targetBytes(limit: nil)
        let projection = DriveQuotaMath.projection(usage: 1_000, selectedBytes: 5_000, target: target)
        XCTAssertEqual(projection.remainingBytes, 0)
        XCTAssertTrue(projection.isUnderLimit)
    }
}
