import XCTest
@testable import MyClicky

@MainActor
final class CaptureRenameTests: XCTestCase {
    private let original = URL(fileURLWithPath: "/tmp/shots/qw36.png")

    func testKeepsFolderAndAddsMissingExtension() {
        let renamed = AssistantController.renamedCaptureURL(original, to: "login bug")
        XCTAssertEqual(renamed?.path, "/tmp/shots/login bug.png")
    }

    func testTypedExtensionIsKept() {
        let renamed = AssistantController.renamedCaptureURL(original, to: "login-bug.png")
        XCTAssertEqual(renamed?.path, "/tmp/shots/login-bug.png")
    }

    func testTrimsWhitespaceAndReplacesSeparators() {
        let renamed = AssistantController.renamedCaptureURL(original, to: "  a/b:c  ")
        XCTAssertEqual(renamed?.lastPathComponent, "a-b-c.png")
    }

    func testRejectsEmptyAndHiddenNames() {
        XCTAssertNil(AssistantController.renamedCaptureURL(original, to: "   "))
        XCTAssertNil(AssistantController.renamedCaptureURL(original, to: ".hidden"))
    }

    func testFolderWithoutExtensionStaysBare() {
        let folder = URL(fileURLWithPath: "/tmp/shots/Notes")
        let renamed = AssistantController.renamedCaptureURL(folder, to: "Archive")
        XCTAssertEqual(renamed?.path, "/tmp/shots/Archive")
    }
}
