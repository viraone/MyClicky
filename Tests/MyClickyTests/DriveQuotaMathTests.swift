import XCTest
@testable import MyClicky

final class DriveQuotaMathTests: XCTestCase {
    func testTargetBytesUsesFreeTierWhenUnlimited() {
        XCTAssertEqual(DriveQuotaMath.targetBytes(limit: nil), DriveQuotaMath.freeTierBytes)
    }

    func testFreeTierMatchesGoogleFreeAccountLimit() {
        // What Drive's `about.storageQuota.limit` returns for a free account.
        XCTAssertEqual(DriveQuotaMath.freeTierBytes, 16_106_127_360)
    }

    @MainActor func testByteTextUsesBinaryUnitsLikeGoogle() {
        // 17.85 decimal GB is what Google One displayed as 16.62 GB.
        XCTAssertEqual(DriveCleanupPlanner.byteText(17_850_000_000), "16.62 GB")
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
        // 17.85 decimal GB (the 16.62 GB Google One showed) minus 1 GB.
        let projection = DriveQuotaMath.projection(usage: 17_850_000_000, selectedBytes: 1_000_000_000, target: target)
        XCTAssertEqual(projection.remainingBytes, 16_850_000_000)
        XCTAssertEqual(projection.overBytes, 16_850_000_000 - 16_106_127_360)
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
