import AppKit
import CoreGraphics

/// Press-and-hold Option+Command+C. Hold begins listening; releasing any part
/// of the chord (the C key or either modifier) ends the hold and submits.
///
/// Uses a CGEventTap so the chord (and its auto-repeats) is swallowed instead
/// of being delivered to the focused app — otherwise macOS plays the alert
/// sound on every key repeat while holding.
@MainActor
final class AssistantHotkeyMonitor {
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitors: [Any] = []
    private var holding = false

    /// The letter key completing the ⌥⌘ chord (default 8 = "C").
    private let keyCode: Int64
    private static let chordFlags: CGEventFlags = [.maskAlternate, .maskCommand]

    init(keyCode: Int64 = 8) {
        self.keyCode = keyCode
    }

    func start() {
        if startEventTap() { return }
        startFallbackMonitors()
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        fallbackMonitors.forEach { NSEvent.removeMonitor($0) }
        fallbackMonitors.removeAll()
    }

    // MARK: - Event tap (preferred: consumes the chord)

    private func startEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<AssistantHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // The tap runs on the main run loop, so this is main-thread safe.
                return MainActor.assumeIsolated {
                    monitor.handleTap(type: type, event: event)
                }
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard eventKeyCode == keyCode, chordIsSatisfied(event.flags) else {
                return Unmanaged.passUnretained(event)
            }
            if !holding {
                holding = true
                onHoldBegan?()
            }
            return nil // swallow, including auto-repeats

        case .keyUp:
            let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard holding, eventKeyCode == keyCode else {
                return Unmanaged.passUnretained(event)
            }
            endHold()
            return nil

        case .flagsChanged:
            if holding, !chordIsSatisfied(event.flags) {
                endHold()
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func chordIsSatisfied(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && flags.contains(.maskCommand)
            && !flags.contains(.maskControl) && !flags.contains(.maskShift)
    }

    // MARK: - Fallback (observe-only NSEvent monitors)

    private func startFallbackMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handleFallback(event) }
        }) {
            fallbackMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleFallback(event)
            return event
        }) {
            fallbackMonitors.append(local)
        }
    }

    private func handleFallback(_ event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        switch event.type {
        case .keyDown:
            guard !holding, !event.isARepeat,
                  event.keyCode == UInt16(keyCode),
                  modifiers == [.option, .command] else { return }
            holding = true
            onHoldBegan?()
        case .keyUp:
            guard holding, event.keyCode == UInt16(keyCode) else { return }
            endHold()
        case .flagsChanged:
            guard holding, !modifiers.contains([.option, .command]) else { return }
            endHold()
        default:
            break
        }
    }

    private func endHold() {
        holding = false
        onHoldEnded?()
    }
}
