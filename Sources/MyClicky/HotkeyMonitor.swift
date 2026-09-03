import AppKit
import CoreGraphics

/// Global Control+Option+X hotkey for region capture. Uses a CGEventTap
/// (same mechanism as the assistant hotkey) with NSEvent monitors as a
/// fallback, since event taps survive app re-signing more reliably.
@MainActor
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?

    private var tap: CFMachPort?
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
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            guard keyCode == Self.keyCodeX,
                  flags.contains(.maskControl), flags.contains(.maskAlternate),
                  !flags.contains(.maskCommand), !flags.contains(.maskShift),
                  !event.getIntegerValueField(.keyboardEventAutorepeat).isNonZero
            else {
                return Unmanaged.passUnretained(event)
            }
            onTrigger?()
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
