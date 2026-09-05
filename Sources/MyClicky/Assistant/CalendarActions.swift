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
        case eventNotFound(String)
        case nothingToChange

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "MyClicky needs Calendar access — allow it in System Settings → Privacy & Security → Calendars."
            case .noDefaultCalendar:
                "No writable calendar is set up on this Mac."
            case .badDate(let raw):
                "Couldn't understand the date/time \u{201c}\(raw)\u{201d}."
            case .eventNotFound(let what):
                "Couldn't find an event matching \u{201c}\(what)\u{201d} on that day."
            case .nothingToChange:
                "Nothing to change — say what the event should become."
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

    /// Changes an existing event's title and/or time. `title` and `start`
    /// identify it — the name it currently has (nil when the user never said
    /// one, e.g. "my 4 PM event") and the day/time it currently sits at —
    /// and the `new*` parameters are the changes; at least one is required.
    /// Calendar's event inspector is the same kind of popover as its quick
    /// entry field above, so editing goes through EventKit for the same
    /// reason creation does.
    static func updateEvent(title: String?, start: String, newTitle: String?,
                            newStart: String?, newEnd: String?) async throws -> String {
        guard newTitle != nil || newStart != nil || newEnd != nil else {
            throw CalendarError.nothingToChange
        }
        guard try await store.requestFullAccessToEvents() else {
            log.notice("calendar access denied")
            throw CalendarError.accessDenied
        }
        guard let target = parseDate(start) else { throw CalendarError.badDate(start) }
        guard let event = findEvent(titled: title, near: target) else {
            let described = title ?? DateFormatter.localizedString(from: target, dateStyle: .none, timeStyle: .short)
            log.notice("no event matched \(described, privacy: .public)")
            throw CalendarError.eventNotFound(described)
        }

        let previousTitle = event.title ?? ""
        if let newTitle { event.title = newTitle }
        if let newStart {
            guard let date = parseDate(newStart) else { throw CalendarError.badDate(newStart) }
            // Moving only the start keeps the event the length it already
            // was, rather than silently stretching it to the old end time.
            let duration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = date
            if newEnd == nil { event.endDate = date.addingTimeInterval(duration) }
        }
        if let newEnd {
            guard let date = parseDate(newEnd) else { throw CalendarError.badDate(newEnd) }
            event.endDate = date
        }
        guard event.endDate > event.startDate else {
            throw CalendarError.badDate(newEnd ?? newStart ?? start)
        }
        // .thisEvent so editing one occurrence of a repeating event doesn't
        // silently rewrite the whole series.
        try store.save(event, span: .thisEvent)

        let when = DateFormatter.localizedString(from: event.startDate, dateStyle: .medium, timeStyle: .short)
        var summary = "Updated \u{201c}\(previousTitle)\u{201d}"
        if let newTitle, newTitle != previousTitle { summary += " — now \u{201c}\(newTitle)\u{201d}" }
        summary += ", \(when)."
        log.notice("updated event \(previousTitle, privacy: .public) at \(when, privacy: .public)")
        return summary
    }

    /// Picks the event on `target`'s day that best matches `title` — an exact
    /// name beats a partial one — and, among equally good matches, the one
    /// starting closest to `target`. With no title (or one that matches
    /// nothing) it falls back to the event sitting at that time, so "my 4 PM
    /// event" works when the user never knew what it was called.
    private static func findEvent(titled title: String?, near target: Date) -> EKEvent? {
        let day = Calendar.current.startOfDay(for: target)
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: day, end: nextDay, calendars: nil))
        let needle = (title ?? "").lowercased().trimmingCharacters(in: .whitespaces)

        func rank(_ event: EKEvent) -> Int? {
            let name = (event.title ?? "").lowercased()
            if !needle.isEmpty, !name.isEmpty {
                if name == needle { return 0 }
                if name.contains(needle) || needle.contains(name) { return 1 }
            }
            // Name didn't help — only accept an event that's actually at the
            // time we were given, so a vague match can't rewrite the wrong one.
            return abs(event.startDate.timeIntervalSince(target)) < 900 ? 2 : nil
        }

        return events.compactMap { event -> (event: EKEvent, rank: Int, distance: TimeInterval)? in
            guard let rank = rank(event) else { return nil }
            return (event, rank, abs(event.startDate.timeIntervalSince(target)))
        }
        .min { ($0.rank, $0.distance) < ($1.rank, $1.distance) }?.event
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
