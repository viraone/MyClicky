import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class AssistantHotkeyMonitorTests: XCTestCase {
    func testEventTapConsumesHoldAndRepeatThenEndsOnceOnRelease() async throws {
        let monitor = AssistantHotkeyMonitor()
        let began = expectation(description: "hold began")
        let ended = expectation(description: "hold ended")
        monitor.onHoldBegan = { began.fulfill() }
        monitor.onHoldEnded = { ended.fulfill() }
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        down.flags = [.maskAlternate, .maskCommand]
        XCTAssertNil(monitor.handleTap(type: .keyDown, event: down))
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(monitor.handleTap(type: .keyDown, event: down))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false))
        XCTAssertNil(monitor.handleTap(type: .keyUp, event: up))
        XCTAssertNotNil(monitor.handleTap(type: .keyUp, event: up))
        await fulfillment(of: [began, ended], timeout: 1, enforceOrder: true)
    }

    func testLocalFallbackWorksInsideActivatingPanelAndEndsOnModifierRelease() async throws {
        let panel = KeyablePanel(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.close() }
        let monitor = AssistantHotkeyMonitor()
        let began = expectation(description: "local hold began")
        let ended = expectation(description: "modifier released")
        monitor.onHoldBegan = { began.fulfill() }
        monitor.onHoldEnded = { ended.fulfill() }
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .command],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        monitor.handleFallback(down)
        monitor.handleFallback(down)
        let flags = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
        monitor.handleFallback(flags)
        monitor.handleFallback(flags)
        await fulfillment(of: [began, ended], timeout: 1, enforceOrder: true)
    }
}
