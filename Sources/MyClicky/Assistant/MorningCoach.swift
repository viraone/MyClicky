import Foundation

/// One line of the Morning Clicky chat.
struct MorningMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, clicky }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

/// The "Morning Clicky" chat: a start-of-day check-in where Clicky plays
/// life coach first (sleep, water, coffee) and then briefs the user on where
/// they left off, using the local activity log and its own past chats.
///
/// Conversations persist to
/// ~/Library/Application Support/MyClicky/morning-chats.json so tomorrow's
/// chat remembers what was said today.
@MainActor
final class MorningCoach {
    private(set) var messages: [MorningMessage] = []
    /// Full history of past days, newest last. Today's messages live in `messages`.
    private var pastChats: [[MorningMessage]] = []
    var onChange: (() -> Void)?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyClicky/morning-chats.json")
    }

    init() {
        load()
    }

    var userName: String {
        // "Viradeth Xay-Ananh" → "Viradeth"
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    func append(_ role: MorningMessage.Role, _ text: String) {
        messages.append(MorningMessage(role: role, text: text))
        save()
        onChange?()
    }

    func clearToday() {
        if !messages.isEmpty { pastChats.append(messages) }
        messages = []
        save()
        onChange?()
    }

    /// Does the utterance open a morning chat? ("good morning clicky", "morning clicky").
    static func isGreeting(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("clicky") && (t.contains("good morning") || t.hasPrefix("morning"))
    }

    // MARK: - Context for Claude

    /// Everything Clicky knows going into this reply: who, when, what happened
    /// in the last work sessions, and what was said in earlier morning chats.
    func contextBrief() -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d, h:mm a"
        var out = "User's first name: \(userName)\nNow: \(fmt.string(from: now))\n\n"
        out += ActivityLog.digest(days: 3)
        if let last = pastChats.last, let first = last.first {
            let day = DateFormatter()
            day.dateFormat = "EEEE MMM d"
            out += "\n\nPrevious morning chat (\(day.string(from: first.date))):\n"
            out += last.suffix(8).map { "\($0.role == .user ? "User" : "Clicky"): \($0.text)" }.joined(separator: "\n")
        }
        return out
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var today: [MorningMessage]
        var past: [[MorningMessage]]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        pastChats = store.past
        // A chat from an earlier day rolls into history so each morning starts clean.
        if let first = store.today.first, !Calendar.current.isDateInToday(first.date) {
            pastChats.append(store.today)
            messages = []
        } else {
            messages = store.today
        }
        pastChats = Array(pastChats.suffix(14))
    }

    private func save() {
        let store = Store(today: messages, past: Array(pastChats.suffix(14)))
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

// MARK: - Activity digest

extension ActivityLog {
    /// A plain-text summary of the last `days` of local activity for Claude:
    /// top apps and sites, the questions/dictations/commands the user gave
    /// Clicky, break-coach outcomes, and when the last session ended.
    static func digest(days: Int) -> String {
        let iso = ISO8601DateFormatter()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var events: [(ts: Date, type: String, d: [String: String])] = []
        for offset in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let file = logDirectory.appendingPathComponent("events-\(day.string(from: date)).jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let type = obj["type"], let ts = obj["ts"].flatMap(iso.date) else { continue }
                events.append((ts, type, obj))
            }
        }
        events.sort { $0.ts < $1.ts }
        guard let last = events.last else {
            return "Activity log: nothing recorded in the last \(days) days (first time using Clicky, or a fresh start)."
        }

        var appMinutes: [String: Int] = [:]
        var siteMinutes: [String: Int] = [:]
        var asked: [String] = []
        var dictated: [String] = []
        var commanded: [String] = []
        var breaksTaken = 0, breaksSnoozed = 0, breaksDue = 0
        for e in events {
            switch e.type {
            case "sample":
                if let app = e.d["app"] { appMinutes[app, default: 0] += 1 }
                if let url = e.d["url"], let host = URL(string: url)?.host {
                    siteMinutes[host.replacingOccurrences(of: "www.", with: ""), default: 0] += 1
                }
            case "ask": if let t = e.d["text"] { asked.append(t) }
            case "dictate": if let t = e.d["text"] { dictated.append(t) }
            case "do", "talk": if let t = e.d["text"] { commanded.append(t) }
            case "break-taken": breaksTaken += 1
            case "break-snoozed": breaksSnoozed += 1
            case "break-due": breaksDue += 1
            default: break
            }
        }

        let when = DateFormatter()
        when.dateFormat = "EEEE h:mm a"
        func top(_ m: [String: Int]) -> String {
            m.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ~\($0.value) min" }.joined(separator: ", ")
        }
        func recent(_ list: [String], _ n: Int) -> String {
            list.suffix(n).map { "- " + $0.prefix(140) }.joined(separator: "\n")
        }

        var out = "Activity log, last \(days) days (local, this Mac only):\n"
        out += "Last activity: \(when.string(from: last.ts))\n"
        if !appMinutes.isEmpty { out += "Apps: \(top(appMinutes))\n" }
        if !siteMinutes.isEmpty { out += "Sites: \(top(siteMinutes))\n" }
        if breaksDue > 0 { out += "Break coach: \(breaksDue) check-ins, \(breaksTaken) breaks taken, \(breaksSnoozed) snoozed\n" }
        if !commanded.isEmpty { out += "Commands they gave Clicky (newest last):\n\(recent(commanded, 8))\n" }
        if !asked.isEmpty { out += "Questions they asked Clicky (newest last):\n\(recent(asked, 8))\n" }
        if !dictated.isEmpty { out += "Things they dictated (newest last):\n\(recent(dictated, 5))\n" }
        return out
    }
}
