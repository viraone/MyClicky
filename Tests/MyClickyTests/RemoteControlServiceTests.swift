import XCTest
@testable import MyClicky

@MainActor
final class RemoteControlServiceTests: XCTestCase {
    func testCodeAndTerminalTabsAreForwarded() {
        let service = RemoteControlService()
        var tabs: [String] = []
        service.onTab = { tabs.append($0) }

        service.handle("TAB CODE")
        service.handle("TAB TERMINAL")

        XCTAssertEqual(tabs, ["CODE", "TERMINAL"])
    }

    func testVideoCommandsAreForwardedTrimmed() {
        let service = RemoteControlService()
        var commands: [String] = []
        service.onVideo = { commands.append($0) }

        service.handle("VIDEO JOG -3")
        service.handle("VIDEO PLAYPAUSE ")
        service.handle("TAB VIDEO")

        XCTAssertEqual(commands, ["JOG -3", "PLAYPAUSE"])
    }

    func testClassRecordingCommandsAreForwardedTrimmed() {
        let service = RemoteControlService()
        var actions: [String] = []
        service.onClassRec = { actions.append($0) }

        service.handle("CLASSREC START")
        service.handle("CLASSREC STOP ")

        XCTAssertEqual(actions, ["START", "STOP"])
    }

    func testClassRecorderFileStampHasNoSlashesOrColons() {
        let stamp = ClassRecorder.fileStamp(Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertFalse(stamp.contains("/"))
        XCTAssertFalse(stamp.contains(":"))
    }

    func testEnterIsForwardedExactlyOnce() {
        let service = RemoteControlService()
        var presses = 0
        service.onEnter = { presses += 1 }

        service.handle("KEY ENTER")

        XCTAssertEqual(presses, 1)
    }

    func testPasteIsForwardedExactlyOnce() {
        let service = RemoteControlService()
        var pastes = 0
        service.onPaste = { pastes += 1 }

        service.handle("KEY PASTE")

        XCTAssertEqual(pastes, 1)
    }

    func testUnknownKeyCommandIsIgnored() {
        let service = RemoteControlService()
        var keyActions = 0
        service.onEnter = { keyActions += 1 }
        service.onPaste = { keyActions += 1 }

        service.handle("KEY SPACE")
        service.handle("KEY ENTER EXTRA")
        service.handle("KEY PASTE EXTRA")

        XCTAssertEqual(keyActions, 0)
    }

    func testShopifySectionsAreForwardedTrimmed() {
        let service = RemoteControlService()
        var sections: [String] = []
        service.onShopify = { sections.append($0) }

        service.handle("SHOPIFY Orders")
        service.handle("SHOPIFY Online Store ")
        service.handle("SHOPIFY Inventory")
        service.handle("SHOPIFY Bill Pay")

        XCTAssertEqual(sections, ["Orders", "Online Store", "Inventory", "Bill Pay"])
    }

    /// A sub-item whose admin route runs to more than one segment is sent by
    /// its display name and resolves to the whole route.
    func testMultiSegmentShopifySectionResolvesToItsWholeRoute() {
        let service = RemoteControlService()
        var sections: [String] = []
        service.onShopify = { sections.append($0) }

        service.handle("SHOPIFY Inventory")

        XCTAssertEqual(sections, ["Inventory"])
        XCTAssertEqual(ShopifyActions.section(named: sections[0])?.path, "products/inventory")
    }

    func testShopifyTableNoneReplyNamesItsSection() {
        XCTAssertEqual(RemoteControlService.shopifyTableNoneLine(for: "Home"),
                       "SHOPIFY_TABLE_NONE Home")
        XCTAssertEqual(RemoteControlService.shopifyTableNoneLine(for: "Live View"),
                       "SHOPIFY_TABLE_NONE Live View")
    }

    func testExistingTabAliasesRemainForwarded() {
        let service = RemoteControlService()
        var tabs: [String] = []
        service.onTab = { tabs.append($0) }

        service.handle("TAB ASK")
        service.handle("TAB DICTATE")
        service.handle("TAB CAPTURE")
        service.handle("TAB CAPTURE_DICTATE")

        XCTAssertEqual(tabs, ["ASK", "DICTATE", "CAPTURE", "CAPTURE_DICTATE"])
    }
}
