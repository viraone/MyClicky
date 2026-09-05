import AppKit
import CoreGraphics

/// Global Control+Option+X hotkey for region capture. Uses a CGEventTap
/// (same mechanism as the assistant hotkey) with NSEvent monitors as a
/// fallback, since event taps survive app re-signing more reliably.
@MainActor
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?

    // Read from the CGEventTap callback, which does not arrive on the main
    // actor — see the note in startEventTap.
    nonisolated(unsafe) private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let keyCodeX: Int64 = 7

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
            // Balances the passRetained in startEventTap, after the source is
            // off the run loop so no callback can still be in flight.
            Unmanaged.passUnretained(self).release()
        }
        tap = nil
        runLoopSource = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: - Event tap (preferred: swallows the chord)

    private func startEventTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        // Retained: the tap outlives any Swift reference and dereferences this
        // pointer on every key event. `stop()` balances it.
        let refcon = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // No `MainActor.assumeIsolated` here: this callback is not
                // guaranteed to run on the main actor, and asserting it does
                // traps the whole app with SIGTRAP. Same fix as
                // AssistantHotkeyMonitor — `handleTap` is nonisolated, and
                // only `onTrigger` hops to main.
                return monitor.handleTap(type: type, event: event)
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

    nonisolated private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            guard keyCode == Self.keyCodeX,
                  flags.contains(.maskControl), flags.contains(.maskAlternate),
                  !flags.contains(.maskCommand), !flags.contains(.maskShift),
                  !event.getIntegerValueField(.keyboardEventAutorepeat).isNonZero
            else {
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { onTrigger?() }
            }
            return nil // swallow the chord
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Fallback (observe-only NSEvent monitors)

    private func startFallbackMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard event.keyCode == 7, modifiers == [.control, .option], !event.isARepeat else { return } // keyCode 7 = "X"
        onTrigger?()
    }
}

private extension Int64 {
    var isNonZero: Bool { self != 0 }
}
