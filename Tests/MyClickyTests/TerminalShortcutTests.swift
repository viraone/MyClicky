import AppKit
import SwiftTerm
import XCTest
@testable import MyClicky

@MainActor
final class TerminalShortcutTests: XCTestCase {
    private final class RecordingTerminal: LocalProcessTerminalView {
        var sent: [UInt8] = []
        override func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }
    }

    private func panel() -> KeyablePanel {
        _ = NSApplication.shared
        return KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    private func command(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: key,
                        charactersIgnoringModifiers: key, isARepeat: false,
                        keyCode: key == "v" ? 9 : 8)!
    }

    private func withClipboard(_ body: () throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(items)
        }
        try body()
    }

    func testTerminalPasteWithoutFocusPreservesBracketedPaste() {
        withClipboard {
            let panel = panel()
            let terminal = RecordingTerminal(frame: panel.contentView!.bounds)
            panel.contentView!.addSubview(terminal)
            XCTAssertTrue(terminal.responds(to: #selector(NSText.paste(_:))))
            XCTAssertFalse(panel.firstResponder === terminal)
            panel.onPaste = { terminal.paste(panel); return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("echo hello", forType: .string)
            terminal.feed(text: "\u{1b}[?2004h")
            XCTAssertTrue(panel.performKeyEquivalent(with: command("v")))
            XCTAssertEqual(String(decoding: terminal.sent, as: UTF8.self), "\u{1b}[200~echo hello\u{1b}[201~")
        }
    }

    func testTerminalCopyThenEditorPaste() {
        withClipboard {
            let panel = panel()
            let terminal = RecordingTerminal(frame: panel.contentView!.bounds)
            panel.contentView!.addSubview(terminal)
            terminal.feed(text: "hello from terminal")
            terminal.selectAll(nil)
            XCTAssertTrue(panel.makeFirstResponder(terminal))
            XCTAssertTrue(panel.performKeyEquivalent(with: command("c")))
            XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("hello from terminal") == true)
            XCTAssertTrue(terminal.sent.isEmpty, "Command-C must not send Control-C")
            let editor = NSTextView(frame: panel.contentView!.bounds)
            panel.contentView!.addSubview(editor)
            XCTAssertTrue(panel.makeFirstResponder(editor))
            panel.onPaste = { false }
            XCTAssertTrue(panel.performKeyEquivalent(with: command("v")))
            XCTAssertTrue(editor.string.contains("hello from terminal"))
        }
    }

    func testEditorCopyThenTerminalPaste() {
        withClipboard {
            let panel = panel()
            let editor = NSTextView(frame: panel.contentView!.bounds)
            panel.contentView!.addSubview(editor)
            editor.string = "echo hello"
            editor.selectAll(nil)
            panel.makeFirstResponder(editor)
            XCTAssertTrue(panel.performKeyEquivalent(with: command("c")))
            let terminal = RecordingTerminal(frame: panel.contentView!.bounds)
            panel.contentView!.addSubview(terminal)
            panel.onPaste = { terminal.paste(panel); return true }
            XCTAssertTrue(panel.performKeyEquivalent(with: command("v")))
            XCTAssertEqual(String(decoding: terminal.sent, as: UTF8.self), "echo hello")
        }
    }

    func testConsumedImagePasteDoesNotReachEditor() {
        let panel = panel()
        let editor = NSTextView(frame: panel.contentView!.bounds)
        panel.contentView!.addSubview(editor)
        panel.makeFirstResponder(editor)
        var attached = false
        panel.onPaste = { attached = true; return true }
        XCTAssertTrue(panel.performKeyEquivalent(with: command("v")))
        XCTAssertTrue(attached)
        XCTAssertEqual(editor.string, "")
    }

    func testCodeZoomShortcutsAreConsumed() {
        let panel = panel()
        var steps: [Int] = []
        panel.onCodeZoom = { steps.append($0); return true }

        XCTAssertTrue(panel.performKeyEquivalent(with: command("+", modifiers: [.command, .shift])))
        XCTAssertTrue(panel.performKeyEquivalent(with: command("=")))
        XCTAssertTrue(panel.performKeyEquivalent(with: command("-")))
        XCTAssertTrue(panel.performKeyEquivalent(with: command("0")))
        XCTAssertEqual(steps, [1, 1, -1, 0])
    }

    func testTerminalDragSelectsTextInsteadOfMovingPanel() {
        let session = TerminalSession()
        XCTAssertFalse(session.view.mouseDownCanMoveWindow)
    }

    func testTransparentPanelMarginPassesClicksThrough() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { point, bounds in
            NSBezierPath(roundedRect: bounds.insetBy(dx: 24, dy: 24),
                         xRadius: 22, yRadius: 22).contains(point)
        }
        panel.orderFrontRegardless()
        defer { panel.close() }

        panel.refreshMousePassthrough(at: panel.convertPoint(toScreen: NSPoint(x: 12, y: 150)))
        XCTAssertTrue(panel.ignoresMouseEvents)

        panel.refreshMousePassthrough(at: panel.convertPoint(toScreen: NSPoint(x: 300, y: 150)))
        XCTAssertFalse(panel.ignoresMouseEvents)

        panel.refreshMousePassthrough(at: panel.convertPoint(toScreen: NSPoint(x: 25, y: 25)))
        XCTAssertTrue(panel.ignoresMouseEvents, "Rounded transparent corners should not intercept clicks")
    }

    func testPanelLowersForBackgroundAppAndRaisesWhenClickedAgain() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.orderFrontRegardless()
        defer { panel.close() }

        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .normal)

        panel.raiseForPanelInteraction()
        XCTAssertEqual(panel.level, .floating)
    }

    func testDraggingAFolderFromFinderKeepsPanelInFront() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.orderFrontRegardless()
        defer { panel.close() }
        panel.raiseForPanelInteraction()

        // Grab a folder in Finder and drag it over: press, travel, release.
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        XCTAssertEqual(panel.level, .floating, "the press alone must not hide the drop target")
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 400, y: 300))
        XCTAssertEqual(panel.level, .floating, "a drag is not a click on a background window")

        // A plain click in another app still sends the panel back.
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 102))
        XCTAssertEqual(panel.level, .normal)

        // A stray release with no press recorded is ignored.
        panel.raiseForPanelInteraction()
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 100, y: 100))
        XCTAssertEqual(panel.level, .floating)
    }

    func testClickingTheOpenDialogDoesNotRaisePanelOverIt() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.orderFrontRegardless()
        defer { panel.close() }
        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .normal)

        let dialog = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        defer { dialog.close() }
        panel.handleLocalMouseDown(in: dialog)
        XCTAssertEqual(panel.level, .normal, "a click in another window of the app leaves the panel where it is")
        panel.handleLocalMouseDown(in: nil)
        XCTAssertEqual(panel.level, .normal)

        panel.handleLocalMouseDown(in: panel)
        XCTAssertEqual(panel.level, .floating)
    }

    func testNativeDialogClicksDoNotLowerPanelBehindBackgroundApp() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.level = .floating
        panel.orderFrontRegardless()
        defer { panel.close() }

        panel.beginNativeDialog()
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 101))
        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .floating)

        panel.endNativeDialog()
        XCTAssertEqual(panel.level, .floating)
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 101))
        XCTAssertEqual(panel.level, .normal, "normal background clicks should lower Peeky after the picker closes")
    }

    func testFocusOnMountDoesNotStealLaterFieldFocus() async {
        let panel = panel()
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.close() }
        let session = TerminalSession()
        let coordinator = TerminalPane.Coordinator(session)
        coordinator.focusWhenMounted(session.view)
        panel.contentView!.addSubview(session.view)
        await drainMainQueue()
        XCTAssertTrue(panel.firstResponder === session.view)
        let editor = NSTextView(frame: .zero)
        panel.contentView!.addSubview(editor)
        panel.makeFirstResponder(editor)
        coordinator.focusWhenMounted(session.view)
        await drainMainQueue()
        XCTAssertTrue(panel.firstResponder === editor)
    }

    func testLeavingTabCancelsPendingFocus() async {
        let panel = panel()
        let session = TerminalSession()
        panel.contentView!.addSubview(session.view)
        let coordinator = TerminalPane.Coordinator(session)
        coordinator.focusWhenMounted(session.view)
        TerminalPane.dismantleNSView(session.view, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertFalse(panel.firstResponder === session.view)
    }

    func testFocusOnMountDoesNotReclaimKeyWindow() async {
        let panel = panel()
        panel.orderFrontRegardless()
        let session = TerminalSession()
        let coordinator = TerminalPane.Coordinator(session)
        coordinator.focusWhenMounted(session.view)
        panel.contentView!.addSubview(session.view)
        await drainMainQueue()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.firstResponder === session.view)
        XCTAssertTrue(session.view.needsPanelToBecomeKey)
        panel.close()
    }

    func testPendingMountDoesNotReclaimFocusAfterPanelResignsKey() async {
        let panel = panel()
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.close() }
        let session = TerminalSession()
        panel.contentView!.addSubview(session.view)
        let coordinator = TerminalPane.Coordinator(session)
        coordinator.focusWhenMounted(session.view)
        panel.resignKey()
        await drainMainQueue()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.firstResponder === session.view)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
