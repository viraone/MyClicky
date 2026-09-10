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

    private func command(_ key: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
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

    func testFocusOnMountDoesNotStealLaterFieldFocus() async {
        let panel = panel()
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

    // A plain NSView (the terminal) never asks a becomesKeyOnlyIfNeeded panel
    // to become key on click, so ⌘K/⌘V would go nowhere without this.
    func testFocusOnMountMakesPanelKey() async {
        let panel = panel()
        panel.orderFrontRegardless()
        let session = TerminalSession()
        let coordinator = TerminalPane.Coordinator(session)
        coordinator.focusWhenMounted(session.view)
        panel.contentView!.addSubview(session.view)
        await drainMainQueue()
        XCTAssertTrue(panel.isKeyWindow)
        panel.close()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
