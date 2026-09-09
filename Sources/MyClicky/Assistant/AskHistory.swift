import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "askhistory")

/// One answered question on the Ask tab, kept so closing Peeky doesn't lose
/// it — the History list is these, newest first.
struct AskHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var answer: String
    var date: Date
    /// Names of the images that were attached when it was asked (the pixels
    /// aren't kept; the names are enough to know what it was about).
    var attachmentNames: [String] = []
}

/// Ask history on disk: ~/Library/Application Support/MyClicky/ask-history.json.
enum AskHistoryStore {
    static let limit = 500

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("MyClicky", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ask-history.json")
    }

    static func load() -> [AskHistoryEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AskHistoryEntry].self, from: data)
        } catch {
            log.error("couldn't read history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func save(_ entries: [AskHistoryEntry]) {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Array(entries.prefix(limit))).write(to: url, options: .atomic)
        } catch {
            log.error("couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Section label for the list: Today / Yesterday / weekday / date.
    static func dayLabel(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= weekAgo {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = cal.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM d" : "MMMM d, yyyy"
        }
        return formatter.string(from: date)
    }
}
