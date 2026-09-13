import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class CodeTextEditorFocusTests: XCTestCase {
    func testDelayedJumpDoesNotReclaimFocusAfterPanelResignsKey() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(frame: panel.contentView!.bounds)
        let otherField = NSTextField(frame: .zero)
        panel.contentView!.addSubview(editor)
        panel.contentView!.addSubview(otherField)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(otherField)
        panel.resignKey()
        let responderBeforeJump = panel.firstResponder
        defer { panel.close() }

        CodeTextEditor.focusIfPanelIsKey(editor)

        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === responderBeforeJump)
        XCTAssertFalse(panel.firstResponder === editor)
    }

    func testDelayedJumpFocusesEditorWhilePanelIsStillKey() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(frame: panel.contentView!.bounds)
        panel.contentView!.addSubview(editor)
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.close() }

        CodeTextEditor.focusIfPanelIsKey(editor)

        XCTAssertTrue(panel.firstResponder === editor)
    }
}
