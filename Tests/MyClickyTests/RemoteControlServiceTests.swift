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
