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

    func testEnterIsForwardedExactlyOnce() {
        let service = RemoteControlService()
        var presses = 0
        service.onEnter = { presses += 1 }

        service.handle("KEY ENTER")

        XCTAssertEqual(presses, 1)
    }

    func testUnknownKeyCommandIsIgnored() {
        let service = RemoteControlService()
        var presses = 0
        service.onEnter = { presses += 1 }

        service.handle("KEY SPACE")
        service.handle("KEY ENTER EXTRA")

        XCTAssertEqual(presses, 0)
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
