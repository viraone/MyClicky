import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "drive-cleanup")

/// Turns a Drive inventory into a reviewed list of trash candidates.
///
/// Two stages, on purpose. Local heuristics do the cheap, mechanical work of
/// narrowing thousands of files to a shortlist worth thinking about; Claude
/// then judges only that shortlist. Sending an entire Drive to the model would
/// cost a fortune and mostly ask it to re-derive "this file is big and old",
/// which arithmetic already settles.
///
/// Nothing in here mutates Drive. The planner's whole output is a list of
/// suggestions for the review window to show — trashing happens only after
/// someone ticks boxes there and clicks the button.
@MainActor
enum DriveCleanupPlanner {

    /// Why a file made the shortlist. Shown in the review window when Claude
    /// declines to flag it, so a row never appears without an explanation.
    enum Signal: String {
        case emptyDoc = "empty document"
        case zeroBytes = "zero bytes"
        case largeOld = "large and untouched"
        case neverOpened = "never opened"
        case duplicateName = "looks like a duplicate"
    }

    struct Candidate: Identifiable {
        let file: DriveService.InventoryFile
        let signals: [Signal]
        /// Claude's call. False means "shortlisted but Claude says keep it" —
        /// the row still shows, unticked, so the reasoning is visible.
        var flagged: Bool
        var reason: String
        var id: String { file.id }
    }

    // Thresholds picked to be unsurprising rather than clever: a file has to be
    // genuinely large or genuinely stale to earn a place on the shortlist.
    private static let largeFileBytes: Int64 = 100_000_000   // 100 MB
    private static let neverOpenedBytes: Int64 = 10_000_000  // 10 MB
    private static let emptyDocQuota: Int64 = 2_048
    private static let shortlistCap = 150
    private static let emptyCheckCap = 40
    private static let chunkSize = 40

    struct Plan {
        let candidates: [Candidate]
        /// How many files tripped a heuristic in all. `candidates` holds only
        /// the largest `shortlistCap` of them, so when this is bigger the
        /// review window has to say so rather than imply it saw everything.
        let signalledCount: Int
    }

    /// Runs the flagging pass. `status` reports progress for the review window.
    static func plan(
        files: [DriveService.InventoryFile],
        drive: DriveService,
        apiKey: String,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> Plan {
        let (shortlist, signalledCount) = shortlist(from: files)
        guard !shortlist.isEmpty else { return Plan(candidates: [], signalledCount: 0) }

        status("Checking \(min(shortlist.count, emptyCheckCap)) documents for content…")
        let confirmedEmpty = await confirmEmpty(in: shortlist, drive: drive)

        let chunks = stride(from: 0, to: shortlist.count, by: chunkSize).map {
            Array(shortlist[$0..<min($0 + chunkSize, shortlist.count)])
        }
        status("Claude is reviewing \(shortlist.count) candidates…")
        // The chunks don't depend on each other, so run them together: four
        // sequential model calls would make the wait the sum of all of them.
        var candidates: [Candidate] = await withTaskGroup(of: [Candidate].self) { group in
            for chunk in chunks {
                group.addTask { @MainActor in
                    await judge(chunk, confirmedEmpty: confirmedEmpty, apiKey: apiKey)
                }
            }
            var all: [Candidate] = []
            var done = 0
            for await judged in group {
                all.append(contentsOf: judged)
                done += 1
                status("Claude is reviewing candidates… \(done) of \(chunks.count) batches done")
            }
            return all
        }
        try Task.checkCancellation()
        // Biggest wins first — that's the order someone cleaning up wants.
        candidates.sort { $0.file.effectiveBytes > $1.file.effectiveBytes }
        return Plan(candidates: candidates, signalledCount: signalledCount)
    }

    // MARK: - Stage 1: local heuristics

    /// The mechanical narrowing pass. Anything that trips no signal at all is
    /// never shown to Claude and never reaches the review window.
    private static func shortlist(
        from files: [DriveService.InventoryFile]
    ) -> (rows: [(file: DriveService.InventoryFile, signals: [Signal])], total: Int) {
        let now = Date()
        let duplicateNames = duplicateNameIDs(in: files)

        var rows: [(DriveService.InventoryFile, [Signal])] = []
        for file in files {
            var signals: [Signal] = []
            // "Last touched" is the later of opened and modified: a file you
            // edited but never re-opened isn't stale.
            let touched = [file.viewedByMeTime, file.modifiedTime].compactMap { $0 }.max()
            let yearsIdle = touched.map { now.timeIntervalSince($0) / (365 * 24 * 3600) } ?? .infinity

            if file.effectiveBytes == 0 {
                signals.append(.zeroBytes)
            }
            if file.effectiveBytes >= largeFileBytes, yearsIdle >= 1 {
                signals.append(.largeOld)
            }
            if file.viewedByMeTime == nil, yearsIdle >= 2, file.effectiveBytes >= neverOpenedBytes {
                signals.append(.neverOpened)
            }
            if file.isGoogleNative, let quota = file.quotaBytes, quota <= emptyDocQuota,
               unchangedSinceCreation(file) {
                signals.append(.emptyDoc)
            }
            if duplicateNames.contains(file.id) {
                signals.append(.duplicateName)
            }
            if !signals.isEmpty { rows.append((file, signals)) }
        }

        let capped = rows
            .sorted { $0.0.effectiveBytes > $1.0.effectiveBytes }
            .prefix(shortlistCap)
            .map { (file: $0.0, signals: $0.1) }
        return (capped, rows.count)
    }

    /// A doc never edited after it was made is the classic "opened it, typed
    /// nothing, closed the tab" leftover. Five minutes of slack absorbs the
    /// gap Drive leaves between creating and first saving a file.
    private static func unchangedSinceCreation(_ file: DriveService.InventoryFile) -> Bool {
        guard let created = file.createdTime, let modified = file.modifiedTime else { return false }
        return modified.timeIntervalSince(created) < 300
    }

    /// IDs of files whose names read like a second copy — "Report (1)",
    /// "Copy of Report". Only the copies are returned, never the original.
    private static func duplicateNameIDs(in files: [DriveService.InventoryFile]) -> Set<String> {
        var ids: Set<String> = []
        for file in files {
            let name = file.name.lowercased()
            if name.range(of: #"\(\d+\)(\.[a-z0-9]+)?$"#, options: .regularExpression) != nil
                || name.hasPrefix("copy of ")
                || name.range(of: #"\bcopy\b(\.[a-z0-9]+)?$"#, options: .regularExpression) != nil {
                ids.insert(file.id)
            }
        }
        return ids
    }

    // MARK: - Stage 2: confirm emptiness

    /// "Small quota" is a guess; exporting the text is the fact. Bounded, and
    /// only for the docs the heuristic already suspects, so a big Drive doesn't
    /// turn into hundreds of export calls.
    private static func confirmEmpty(
        in shortlist: [(file: DriveService.InventoryFile, signals: [Signal])],
        drive: DriveService
    ) async -> Set<String> {
        let suspects = Array(shortlist.filter { $0.signals.contains(.emptyDoc) }.prefix(emptyCheckCap))
        guard !suspects.isEmpty else { return [] }

        // Run them concurrently: these are dozens of independent round trips,
        // and one at a time leaves someone staring at a spinner for the sum of
        // every network wait instead of the longest one.
        return await withTaskGroup(of: String?.self) { group in
            for row in suspects {
                group.addTask { @MainActor in
                    guard let text = try? await drive.fileText(
                        id: row.file.id, name: row.file.name, mimeType: row.file.mimeType
                    ) else { return nil }
                    // fileText prefixes "Document: <name>\n\n", so drop that
                    // header before deciding whether anything is in there.
                    let body = text
                        .components(separatedBy: "\n\n")
                        .dropFirst()
                        .joined(separator: "\n\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return body.isEmpty ? row.file.id : nil
                }
            }
            var empty: Set<String> = []
            for await id in group {
                if let id { empty.insert(id) }
            }
            return empty
        }
    }

    // MARK: - Stage 3: Claude judges the shortlist

    private static let system = """
    You are helping someone clean up their personal Google Drive. You are given \
    metadata for files they own that a heuristic pass has already flagged as \
    possibly disposable. Decide, for each one, whether it is a reasonable \
    candidate to move to the trash.

    Say trash: true only when the file looks genuinely disposable — an empty \
    document nobody ever wrote in, an obvious duplicate copy, a large media file \
    untouched for years. Say trash: false when the name suggests it matters \
    (taxes, contracts, passports, medical, legal, financial records, anything \
    that reads like an original or a one-of-a-kind), when it has been opened \
    recently, or when you are unsure. Being wrong in the direction of keeping a \
    file costs the user nothing; being wrong the other way costs them a file.

    The person reviews every suggestion on screen and ticks the ones to remove, \
    so your job is a good recommendation with a short honest reason — not a \
    final decision. Files only ever move to Drive's trash, recoverable for 30 \
    days; nothing is permanently deleted.

    Reply with JSON only: {"verdicts": [{"id": "<file id>", "trash": true|false, \
    "reason": "<at most 12 words, why>"}]}. Include every id you were given.
    """

    private static func judge(
        _ chunk: [(file: DriveService.InventoryFile, signals: [Signal])],
        confirmedEmpty: Set<String>,
        apiKey: String
    ) async -> [Candidate] {
        // Model comes from AnthropicService's default — one place decides what
        // the whole app runs on, rather than this route drifting on its own.
        let claude = AnthropicService(apiKey: apiKey)

        let rows = chunk.map { row -> [String: Any] in
            var entry: [String: Any] = [
                "id": row.file.id,
                "name": row.file.name,
                "type": friendlyType(row.file.mimeType),
                "size": byteText(row.file.effectiveBytes),
                "signals": row.signals.map(\.rawValue),
            ]
            entry["created"] = row.file.createdTime.map(dayText) ?? "unknown"
            entry["modified"] = row.file.modifiedTime.map(dayText) ?? "unknown"
            entry["lastOpenedByUser"] = row.file.viewedByMeTime.map(dayText) ?? "never"
            if confirmedEmpty.contains(row.file.id) {
                entry["contentCheck"] = "exported text is empty"
            }
            return entry
        }
        let payload = (try? JSONSerialization.data(withJSONObject: ["files": rows]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // Fall back to "shortlisted, undecided" rather than losing the rows —
        // the review window can still show them with their heuristic reason.
        func unjudged() -> [Candidate] {
            chunk.map {
                Candidate(file: $0.file, signals: $0.signals, flagged: false,
                          reason: $0.signals.map(\.rawValue).joined(separator: ", "))
            }
        }

        do {
            let json = try await claude.requestJSON(
                system: system,
                userText: payload,
                maxTokens: 16_000,
                timeout: 180,
                // Judging file metadata against a name is pattern-matching, not
                // deep reasoning, and the review screen catches anything it gets
                // wrong — so the default (high) buys latency without buying
                // accuracy here.
                effort: "medium"
            )
            guard let verdicts = json["verdicts"] as? [[String: Any]] else { return unjudged() }
            var byID: [String: (Bool, String)] = [:]
            for verdict in verdicts {
                guard let id = verdict["id"] as? String else { continue }
                byID[id] = (verdict["trash"] as? Bool ?? false,
                            verdict["reason"] as? String ?? "")
            }
            return chunk.map { row in
                let (trash, reason) = byID[row.file.id] ?? (false, "")
                return Candidate(
                    file: row.file,
                    signals: row.signals,
                    flagged: trash,
                    reason: reason.isEmpty ? row.signals.map(\.rawValue).joined(separator: ", ") : reason
                )
            }
        } catch {
            log.error("Claude flagging failed: \(error.localizedDescription, privacy: .public)")
            return unjudged()
        }
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayText(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func friendlyType(_ mimeType: String) -> String {
        switch mimeType {
        case "application/vnd.google-apps.document": return "Google Doc"
        case "application/vnd.google-apps.spreadsheet": return "Google Sheet"
        case "application/vnd.google-apps.presentation": return "Google Slides"
        case "application/vnd.google-apps.form": return "Google Form"
        case "application/pdf": return "PDF"
        case let mime where mime.hasPrefix("video/"): return "Video"
        case let mime where mime.hasPrefix("image/"): return "Image"
        case let mime where mime.hasPrefix("audio/"): return "Audio"
        default:
            return mimeType.split(separator: "/").last.map(String.init) ?? "File"
        }
    }
}
