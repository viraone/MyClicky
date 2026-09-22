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
        return KeyablePanel(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    private func assertInFront(_ front: NSWindow, of back: NSWindow,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let windows = try XCTUnwrap(NSWindow.windowNumbers(), file: file, line: line).map(\.intValue)
        let frontIndex = try XCTUnwrap(windows.firstIndex(of: front.windowNumber), file: file, line: line)
        let backIndex = try XCTUnwrap(windows.firstIndex(of: back.windowNumber), file: file, line: line)
        XCTAssertLessThan(frontIndex, backIndex, file: file, line: line)
    }

    private func withAppDelegate(_ body: (AppDelegate) throws -> Void) rethrows {
        let previous = NSApp.delegate
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        defer { NSApp.delegate = previous }
        try body(delegate)
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

    func testPanelLowersForBackgroundAppAndRaisesWhenClickedAgain() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        let backgroundWindow = self.panel()
        backgroundWindow.orderFrontRegardless()
        panel.raiseForPanelInteraction()
        defer { panel.close(); backgroundWindow.close() }

        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .normal)
        try assertInFront(backgroundWindow, of: panel)

        panel.raiseForPanelInteraction()
        XCTAssertEqual(panel.level, .normal)
        try assertInFront(panel, of: backgroundWindow)
    }

    func testMissionControlSelectionCanCoverPanelWithoutActivationOrMouseEvents() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        let selectedWindow = self.panel()
        selectedWindow.level = .normal
        selectedWindow.orderFrontRegardless()
        defer { panel.close(); selectedWindow.close() }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp.keyWindow

        panel.raiseForPanelInteraction()
        try assertInFront(panel, of: selectedWindow)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertTrue(panel.collectionBehavior.contains(.managed))

        // Model Mission Control's resulting order, including reselecting the
        // app already beneath Peeky: no activation notification or mouse click.
        selectedWindow.orderFrontRegardless()
        panel.refreshMousePassthrough(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        try assertInFront(selectedWindow, of: panel)

        panel.handleLocalMouseDown(in: panel)
        try assertInFront(panel, of: selectedWindow)
        selectedWindow.orderFrontRegardless()
        try assertInFront(selectedWindow, of: panel)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
    }

    func testSelectingPeekyThroughApplicationActivationRaisesWithoutRepinning() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.raiseForPanelInteraction()
        let selectedWindow = self.panel()
        selectedWindow.orderFrontRegardless()
        defer { panel.close(); selectedWindow.close() }

        try withAppDelegate { _ in
            // A Mission Control selection may begin as a click delivered to
            // Dock rather than to Peeky's local mouse monitor.
            panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            try assertInFront(panel, of: selectedWindow)
            panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 100, y: 100))
            try assertInFront(panel, of: selectedWindow)
            XCTAssertEqual(panel.level, .normal)
            XCTAssertTrue(panel.collectionBehavior.contains(.managed))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))

            selectedWindow.orderFrontRegardless()
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            try assertInFront(selectedWindow, of: panel)
        }
    }

    func testSelectingPeekyAsKeyWindowRaisesWithoutApplicationActivation() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.raiseForPanelInteraction()
        let selectedWindow = self.panel()
        selectedWindow.orderFrontRegardless()
        defer { panel.close(); selectedWindow.close() }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        try assertInFront(panel, of: selectedWindow)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        selectedWindow.orderFrontRegardless()
        try assertInFront(selectedWindow, of: panel)
    }

    func testReopeningPeekyRaisesVisibleCardAtNormalLevel() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.raiseForPanelInteraction()
        let selectedWindow = self.panel()
        selectedWindow.orderFrontRegardless()
        defer { panel.close(); selectedWindow.close() }

        try withAppDelegate { delegate in
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            try assertInFront(panel, of: selectedWindow)
            XCTAssertEqual(panel.level, .normal)
            selectedWindow.orderFrontRegardless()
            try assertInFront(selectedWindow, of: panel)
        }
    }

    func testSystemSelectionDoesNotRaiseOverNativePickerOrCleanupWindow() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.raiseForPanelInteraction()
        let otherWindow = self.panel()
        defer { panel.close(); otherWindow.close() }

        try withAppDelegate { delegate in
            panel.beginNativeDialog()
            otherWindow.level = .floating
            otherWindow.orderFrontRegardless()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            try assertInFront(otherWindow, of: panel)
            panel.makeKey()
            try assertInFront(otherWindow, of: panel)
            XCTAssertEqual(panel.level, .floating)
            panel.endNativeDialog()
            panel.resignKey()

            // Drive/Gmail cleanup makes its own window key before NSApp.activate.
            otherWindow.level = .normal
            otherWindow.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            try assertInFront(otherWindow, of: panel)
            XCTAssertTrue(NSApp.keyWindow === otherWindow)
            XCTAssertEqual(panel.level, .normal)
        }
    }

    func testSystemSelectionDoesNotShowHiddenPanelOrReorderFloatingModes() throws {
        let panel = panel()
        var lowerForBackgroundClick = true
        panel.enableTransparentMarginPassthrough(interactiveRegion: { _, _ in true },
                                                shouldLowerForBackgroundClick: { lowerForBackgroundClick })
        let otherWindow = self.panel()
        defer { panel.close(); otherWindow.close() }

        try withAppDelegate { delegate in
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            XCTAssertFalse(panel.isVisible)

            lowerForBackgroundClick = false
            panel.raiseForPanelInteraction()
            otherWindow.level = .floating
            otherWindow.orderFrontRegardless()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            panel.makeKey()
            try assertInFront(otherWindow, of: panel)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        }
    }

    func testDraggingAFolderDoesNotExplicitlyLowerVisibleDropTarget() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        let backgroundWindow = self.panel()
        backgroundWindow.orderFrontRegardless()
        panel.raiseForPanelInteraction()
        defer { panel.close(); backgroundWindow.close() }

        // Grab a folder in Finder and drag it over: press, travel, release.
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        try assertInFront(panel, of: backgroundWindow)
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 400, y: 300))
        try assertInFront(panel, of: backgroundWindow)

        // A plain click in another app still sends the panel back.
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 102))
        try assertInFront(backgroundWindow, of: panel)

        // A stray release with no press recorded is ignored.
        panel.raiseForPanelInteraction()
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 100, y: 100))
        try assertInFront(panel, of: backgroundWindow)
        XCTAssertEqual(panel.level, .normal)
    }

    func testClickingTheOpenDialogDoesNotRaisePanelOverIt() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.orderFrontRegardless()
        defer { panel.close() }
        panel.lowerForBackgroundInteraction()

        let dialog = self.panel()
        dialog.orderFrontRegardless()
        defer { dialog.close() }
        panel.handleLocalMouseDown(in: dialog)
        try assertInFront(dialog, of: panel)
        panel.handleLocalMouseDown(in: nil)
        try assertInFront(dialog, of: panel)

        panel.handleLocalMouseDown(in: panel)
        try assertInFront(panel, of: dialog)
        XCTAssertEqual(panel.level, .normal)
    }

    func testNativeDialogClicksDoNotLowerPanelBehindBackgroundApp() throws {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        let backgroundWindow = self.panel()
        backgroundWindow.orderFrontRegardless()
        panel.raiseForPanelInteraction()
        defer { panel.close(); backgroundWindow.close() }

        panel.beginNativeDialog()
        let dialog = self.panel()
        dialog.level = .floating
        dialog.orderFrontRegardless()
        defer { dialog.close() }
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 101))
        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .floating)
        try assertInFront(panel, of: backgroundWindow)
        panel.handleLocalMouseDown(in: dialog)
        panel.handleLocalMouseDown(in: panel)
        panel.raiseForPanelInteraction()
        try assertInFront(dialog, of: panel)

        dialog.orderOut(nil)
        panel.endNativeDialog()
        XCTAssertEqual(panel.level, .normal)
        XCTAssertTrue(panel.collectionBehavior.contains(.managed))
        try assertInFront(panel, of: backgroundWindow)
        panel.handleBackgroundMouse(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        panel.handleBackgroundMouse(.leftMouseUp, at: NSPoint(x: 101, y: 101))
        try assertInFront(backgroundWindow, of: panel)
    }

    func testNestedNativeDialogsRestorePolicyOnlyAfterLastDialogAndDoNotReopenHiddenPanel() {
        let panel = panel()
        panel.enableTransparentMarginPassthrough { _, _ in true }
        panel.raiseForPanelInteraction()
        defer { panel.close() }
        panel.beginNativeDialog()
        panel.beginNativeDialog()
        panel.endNativeDialog()
        XCTAssertEqual(panel.level, .floating)
        panel.orderOut(nil)
        panel.endNativeDialog()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertTrue(panel.collectionBehavior.contains(.managed))
    }

    func testControllerShowAndPolicyTransitionsDoNotRepinCapture() throws {
        let controller = AssistantPanelController()
        let panel = controller.ensurePanel()
        // Exercise the real controller without rendering a card on the user's desktop.
        panel.contentViewController = nil
        panel.alphaValue = 0
        let hiddenTabs = UserDefaults.standard.object(forKey: AssistantState.hiddenTabsKey)
        controller.state.hiddenTabs = []
        defer {
            controller.hide()
            panel.close()
            if let hiddenTabs {
                UserDefaults.standard.set(hiddenTabs, forKey: AssistantState.hiddenTabsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AssistantState.hiddenTabsKey)
            }
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let backgroundWindow = self.panel()
        backgroundWindow.orderFrontRegardless()
        defer { backgroundWindow.close() }
        let presentations: [(String, () -> Void)] = [
            ("show", { controller.show(near: .zero, on: screen) }),
            ("capture", { controller.showInCorner(on: screen) }),
            ("remote strip", { controller.showAsStrip(on: screen) }),
            ("remote full", { controller.presentFull(near: .zero, on: screen) }),
            ("remote screen", { controller.move(toScreenIndex: 1) }),
            ("restore dot", { controller.expand() }),
        ]
        for (name, present) in presentations {
            controller.state.tab = .captureDictate
            controller.minimize()
            XCTAssertEqual(panel.level, .floating, name)
            XCTAssertTrue(panel.isFloatingPanel, name)
            XCTAssertTrue(panel.collectionBehavior.contains(.transient), name)
            panel.lowerForBackgroundInteraction()
            XCTAssertEqual(panel.level, .floating, name)
            present()
            XCTAssertFalse(controller.state.collapsed, name)
            XCTAssertEqual(panel.level, .normal, name)
            XCTAssertFalse(panel.isFloatingPanel, name)
            XCTAssertTrue(panel.collectionBehavior.contains(.managed), name)
            XCTAssertFalse(panel.collectionBehavior.contains(.transient), name)
            try assertInFront(panel, of: backgroundWindow)
            backgroundWindow.orderFrontRegardless()
            try assertInFront(backgroundWindow, of: panel)
        }

        controller.toggleStrip()
        try assertInFront(panel, of: backgroundWindow)
        XCTAssertEqual(panel.level, .normal)
        controller.state.tab = .video
        panel.lowerForBackgroundInteraction()
        XCTAssertEqual(panel.level, .floating)
        controller.state.tab = .captureDictate
        XCTAssertEqual(panel.level, .normal)
        XCTAssertTrue(panel.collectionBehavior.contains(.managed))

        panel.beginNativeDialog()
        controller.state.tab = .video
        controller.state.tab = .captureDictate
        XCTAssertEqual(panel.level, .floating, "tab changes must not bypass an open picker's guard")
        panel.endNativeDialog()
        XCTAssertEqual(panel.level, .normal)
        XCTAssertTrue(panel.collectionBehavior.contains(.managed))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
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
