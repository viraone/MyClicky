import EventKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "calendar")

/// Creates calendar events through EventKit rather than by driving
/// Calendar.app's UI. Its "Create Quick Event" popover is invisible to the
/// Accessibility API and transient enough that clicking it from a screenshot
/// is unreliable, so the generic AXActions path can't drive it — but events
/// are ordinary data, and EventKit is the OS's real API for them. This isn't
/// a hand-scripted UI cartridge; it's using the right tool for the job.
enum CalendarActions {

    enum CalendarError: LocalizedError {
        case accessDenied
        case noDefaultCalendar
        case badDate(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "MyClicky needs Calendar access — allow it in System Settings → Privacy & Security → Calendars."
            case .noDefaultCalendar:
                "No writable calendar is set up on this Mac."
            case .badDate(let raw):
                "Couldn't understand the date/time \u{201c}\(raw)\u{201d}."
            }
        }
    }

    private static let store = EKEventStore()

    /// Creates an event and returns a short confirmation line. `start`/`end`
    /// are local-time ISO 8601 ("2026-09-03T16:00:00"); `end` defaults to an
    /// hour after `start`.
    static func createEvent(title: String, start: String, end: String?) async throws -> String {
        guard try await store.requestFullAccessToEvents() else {
            log.notice("calendar access denied")
            throw CalendarError.accessDenied
        }
        guard let startDate = parseDate(start) else { throw CalendarError.badDate(start) }
        let endDate = end.flatMap(parseDate) ?? startDate.addingTimeInterval(3600)
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noDefaultCalendar }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        try store.save(event, span: .thisEvent)

        let when = DateFormatter.localizedString(from: startDate, dateStyle: .medium, timeStyle: .short)
        log.notice("created event \(title, privacy: .public) at \(when, privacy: .public)")
        return "Added \u{201c}\(title)\u{201d} to your calendar for \(when)."
    }

    /// Accepts local-time ISO 8601 with or without a timezone, since the
    /// planner produces both.
    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return date }
        }
        return nil
    }
}
