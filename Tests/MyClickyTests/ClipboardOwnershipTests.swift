import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class ClipboardOwnershipTests: XCTestCase {
    func testPasteboardChangeCountDetectsNewerUserCopy() {
        let pasteboard = NSPasteboard(name: .init("MyClickyTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("Peeky capture", forType: .string)
        let peekyChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("Text copied by the user", forType: .string)

        XCTAssertNotEqual(pasteboard.changeCount, peekyChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Text copied by the user")
    }
}
