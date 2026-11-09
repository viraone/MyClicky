import Foundation

/// One scene of a Code Documentary project, as the editor sees it.
struct DocEditScene: Equatable {
    let id: String
    let kind: String
    var heading: String
    var narration: String
    var start: Double?
    var end: Double?
}

enum DocEditError: LocalizedError {
    case noScript
    case badScript(String)
    case unknownScene(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .noScript:
            return "The script.json file is missing."
        case .badScript(let reason):
            return "The script.json file is invalid: \(reason)."
        case .unknownScene(let id):
            return "Unknown scene id: \(id)."
        case .refused(let reason):
            return reason
        }
    }
}

/// A folder holding one Code Documentary project: script.json, timeline.json,
/// audio/ and documentary.mp4. Edits are backed up once into `.edit-backup`
/// before anything is changed, so the whole film can be put back.
final class DocEditProject {
    static let backupFolderName = ".edit-backup"

    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    private var scriptURL: URL { folder.appendingPathComponent("script.json") }
    private var timelineURL: URL { folder.appendingPathComponent("timeline.json") }
    private var movieURL: URL { folder.appendingPathComponent("documentary.mp4") }
    private var audioURL: URL { folder.appendingPathComponent("audio", isDirectory: true) }
    private var backupURL: URL { folder.appendingPathComponent(Self.backupFolderName, isDirectory: true) }
    private var pendingURL: URL { backupURL.appendingPathComponent("pending.json") }

    var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("script.json").path)
    }

    func title() throws -> String {
        let root = try loadScript()
        return root["title"] as? String ?? ""
    }

    func scenes() throws -> [DocEditScene] {
        let root = try loadScript()
        let rawScenes = root["scenes"] as? [[String: Any]] ?? []
        let times = timelineTimes()
        return rawScenes.map { raw in
            let id = raw["id"] as? String ?? ""
            let time = times[id]
            let start: Double?
            let end: Double?
            if let time {
                start = time.start
                end = time.end
            } else {
                start = nil
                end = nil
            }
            return DocEditScene(
                id: id,
                kind: raw["kind"] as? String ?? "",
                heading: raw["heading"] as? String ?? "",
                narration: raw["narration"] as? String ?? "",
                start: start,
                end: end
            )
        }
    }

    func describe() throws -> String {
        let root = try loadScript()
        let filmTitle = root["title"] as? String ?? ""
        let allScenes = try scenes()

        var lines: [String] = []
        if let latestEnd = allScenes.compactMap({ $0.end }).max() {
            lines.append("Film: \"\(filmTitle)\", \(allScenes.count) scenes, \(Self.formatTime(latestEnd)) long.")
        } else {
            lines.append("Film: \"\(filmTitle)\", \(allScenes.count) scenes, unknown length.")
        }
        lines.append("Narrator voice: \(voice() ?? "unknown")")
        lines.append("Scenes (times are where each one plays in the film right now):")

        for (index, scene) in allScenes.enumerated() {
            var line = "\(index + 1). id=\(scene.id) kind=\(scene.kind)"
            if !scene.heading.isEmpty {
                line += " heading=\"\(scene.heading)\""
            }
            if let start = scene.start, let end = scene.end {
                line += " \(Self.formatTime(start))-\(Self.formatTime(end))"
            }
            lines.append(line)
            lines.append("   narration: \"\(scene.narration)\"")
        }

        let pending = pendingSceneIDs()
        if !pending.isEmpty {
            lines.append("Edited but not rendered yet: \(pending.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    func voice() -> String? {
        guard let data = try? Data(contentsOf: audioURL.appendingPathComponent("voice.json")),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let voice = root["voice"] as? String else { return nil }
        return voice
    }

    func setNarration(sceneID: String, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var allScenes = try loadScenes()
        guard let index = allScenes.firstIndex(where: { ($0["id"] as? String) == sceneID }) else {
            throw DocEditError.unknownScene(sceneID)
        }
        guard !trimmed.isEmpty else {
            try recordPending(sceneID)
            throw DocEditError.refused("Narration cannot be empty.")
        }
        try snapshotIfNeeded()
        allScenes[index]["narration"] = trimmed
        try writeScenes(allScenes)
        try recordPending(sceneID)
    }

    func setHeading(sceneID: String, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var allScenes = try loadScenes()
        guard let index = allScenes.firstIndex(where: { ($0["id"] as? String) == sceneID }) else {
            throw DocEditError.unknownScene(sceneID)
        }
        guard !trimmed.isEmpty else {
            throw DocEditError.refused("Heading cannot be empty.")
        }
        try snapshotIfNeeded()
        allScenes[index]["heading"] = trimmed
        try writeScenes(allScenes)
    }

    func deleteScene(sceneID: String) throws {
        var allScenes = try loadScenes()
        guard let index = allScenes.firstIndex(where: { ($0["id"] as? String) == sceneID }) else {
            throw DocEditError.unknownScene(sceneID)
        }
        if (allScenes[index]["kind"] as? String) == "credits" {
            throw DocEditError.refused("Cannot delete the credits scene.")
        }
        guard allScenes.count > 2 else {
            throw DocEditError.refused("A film needs at least 2 scenes.")
        }
        try snapshotIfNeeded()
        allScenes.remove(at: index)
        try writeScenes(allScenes)
        try recordPending(sceneID)
    }

    func pendingSceneIDs() -> [String] {
        guard let data = try? Data(contentsOf: pendingURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let ids = object as? [String] else { return [] }
        return ids.sorted()
    }

    func prepareForRender() throws -> [String] {
        let ids = pendingSceneIDs()
        guard !ids.isEmpty else { return [] }
        let fm = FileManager.default
        for id in ids {
            let wavURL = audioURL.appendingPathComponent("\(id).wav")
            if fm.fileExists(atPath: wavURL.path) {
                try fm.removeItem(at: wavURL)
            }
        }
        try writePending([])
        return ids
    }

    func restoreBackup() throws {
        guard hasBackup else {
            throw DocEditError.refused("There is nothing to restore.")
        }
        let fm = FileManager.default
        let names = ["script.json", "timeline.json", "documentary.mp4"]
        for name in names {
            let current = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: current.path) {
                try? fm.removeItem(at: current)
            }
        }
        if fm.fileExists(atPath: audioURL.path) {
            try? fm.removeItem(at: audioURL)
        }
        for name in names {
            let source = backupURL.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
            }
        }
        let audioBackup = backupURL.appendingPathComponent("audio", isDirectory: true)
        if fm.fileExists(atPath: audioBackup.path) {
            try fm.copyItem(at: audioBackup, to: audioURL)
        }
        try fm.removeItem(at: backupURL)
    }

    /// The exact clock label used in the editor and in describe().
    static func formatTime(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        let minutes = tenths / 600
        let secs = (tenths % 600) / 10
        let frac = tenths % 10
        return String(format: "%d:%02d.%d", minutes, secs, frac)
    }

    // MARK: - Private

    private func loadScript() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw DocEditError.noScript
        }
        let data: Data
        do {
            data = try Data(contentsOf: scriptURL)
        } catch {
            throw DocEditError.badScript("it could not be read")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DocEditError.badScript("it is not valid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw DocEditError.badScript("it is not a JSON object")
        }
        guard (root["scenes"] as? [[String: Any]]) != nil else {
            throw DocEditError.badScript("it has no scenes array")
        }
        return root
    }

    private func loadScenes() throws -> [[String: Any]] {
        let root = try loadScript()
        return root["scenes"] as? [[String: Any]] ?? []
    }

    private func writeScenes(_ allScenes: [[String: Any]]) throws {
        var root = try loadScript()
        root["scenes"] = allScenes
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: scriptURL, options: .atomic)
    }

    private func timelineTimes() -> [String: (start: Double?, end: Double?)] {
        guard let data = try? Data(contentsOf: timelineURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let scenes = root["scenes"] as? [[String: Any]] else {
            return [:]
        }
        var times: [String: (start: Double?, end: Double?)] = [:]
        for scene in scenes {
            guard let id = scene["id"] as? String else { continue }
            times[id] = (start: Self.doubleValue(scene["start"]),
                         end: Self.doubleValue(scene["end"]))
        }
        return times
    }

    /// Copies the original film into `.edit-backup` once. An existing backup
    /// is never overwritten; pending.json alone does not count as a backup.
    private func snapshotIfNeeded() throws {
        guard !hasBackup else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: backupURL.path) {
            try fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
        }
        for source in [scriptURL, timelineURL, movieURL] {
            let destination = backupURL.appendingPathComponent(source.lastPathComponent)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            try fm.copyItem(at: source, to: destination)
        }
        let audioBackup = backupURL.appendingPathComponent("audio", isDirectory: true)
        if fm.fileExists(atPath: audioURL.path), !fm.fileExists(atPath: audioBackup.path) {
            try fm.copyItem(at: audioURL, to: audioBackup)
        }
    }

    private func recordPending(_ id: String) throws {
        var ids = pendingSceneIDs()
        if !ids.contains(id) {
            ids.append(id)
        }
        try writePending(ids.sorted())
    }

    private func writePending(_ ids: [String]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: backupURL.path) {
            try fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(
            withJSONObject: ids,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: pendingURL, options: .atomic)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
