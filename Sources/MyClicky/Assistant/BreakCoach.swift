import AppKit
import CoreGraphics
import Foundation

/// Counts the time spent at the computer and, every 25 minutes of it, asks
/// for a break. Exists because the person using it will otherwise sit for
/// hours.
///
/// Two rules that make it fair rather than nagging:
/// - Time away doesn't count. If the keyboard and mouse go quiet for
///   `awayAfter`, the session is treated as a break already taken and the
///   count starts over when they come back.
/// - It notices what the time was spent in, so the check-in can be about
///   *this* stretch ("forty minutes in Xcode") and not a generic poster.
@MainActor
final class BreakCoach {
    /// One work stretch before a check-in. Overridable for testing:
    /// `defaults write com.local.MyClicky breakCoachIntervalSeconds -int 60`
    /// (delete the key to go back to 25 minutes).
    static var interval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "breakCoachIntervalSeconds")
        return override > 0 ? override : 25 * 60
    }
    /// Quiet for this long and the person is assumed to have stepped away.
    private static let awayAfter: TimeInterval = 5 * 60
    private static let enabledKey = "breakCoachEnabled"

    /// On by default: the point is that it runs without being remembered.
    var enabled: Bool = UserDefaults.standard.object(forKey: BreakCoach.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { restart() } else { tick?.invalidate(); tick = nil }
            onChange?()
        }
    }

    /// Seconds left before the next check-in.
    private(set) var remaining: TimeInterval = BreakCoach.interval
    /// Seconds of continuous computer time in the current stretch, which can
    /// exceed `interval` after a snooze.
    private(set) var elapsed: TimeInterval = 0
    /// Minutes of foreground time per app in this stretch, most-used first.
    var appsThisStretch: [(name: String, minutes: Int)] {
        appSeconds.map { (name: $0.key, minutes: Int($0.value / 60)) }
            .sorted { $0.minutes > $1.minutes }
    }
    private var appSeconds: [String: TimeInterval] = [:]

    /// Fires once when the stretch is up. The receiver decides what to say.
    var onTimeUp: (() -> Void)?
    /// Fires every tick so a countdown can be drawn.
    var onChange: (() -> Void)?

    private var tick: Timer?
    private var lastTick = Date()
    /// Set while a check-in is on screen so the timer waits for an answer
    /// instead of firing again underneath it.
    private var waitingForAnswer = false

    func start() {
        guard enabled else { return }
        restart()
    }

    /// "Taking a break": the stretch is over, count the next one from now.
    func breakTaken() {
        waitingForAnswer = false
        restart()
    }

    /// "Five more minutes": keep the stretch going, ask again shortly.
    func snooze(minutes: Int = 5) {
        waitingForAnswer = false
        remaining = TimeInterval(minutes * 60)
        lastTick = Date()
        onChange?()
    }

    private func restart() {
        remaining = Self.interval
        elapsed = 0
        appSeconds = [:]
        lastTick = Date()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        onChange?()
    }

    private func advance() {
        guard enabled, !waitingForAnswer else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now

        // Away from the keyboard long enough counts as the break itself —
        // and a Mac that slept overnight shouldn't wake up mid-countdown.
        if Self.secondsSinceInput() >= Self.awayAfter || delta > Self.awayAfter {
            if elapsed > 0 { restart() }
            return
        }

        elapsed += delta
        remaining = max(0, remaining - delta)
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            appSeconds[app, default: 0] += delta
        }
        onChange?()

        if remaining <= 0 {
            waitingForAnswer = true
            onTimeUp?()
        }
    }

    /// Seconds since the last keyboard or mouse event anywhere on the Mac.
    private static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    /// "24:13" for the countdown button.
    var remainingLabel: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
