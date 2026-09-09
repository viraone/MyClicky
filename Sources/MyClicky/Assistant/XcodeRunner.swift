import Foundation

/// Builds an Xcode project and runs it in the iOS Simulator, the way ⌘R
/// does in Xcode — but from Peeky, with `xcodebuild`'s few thousand lines
/// boiled down to "building… → ✓ launched" or a short list of errors.
/// Nothing here talks to Claude; it's `xcodebuild` and `simctl` on this Mac.
@MainActor
final class XcodeRunner {
    struct BuildError: Identifiable, Equatable {
        let id = UUID()
        /// Path relative to the project root when possible, for opening in the preview.
        let file: String
        let line: Int
        let message: String
        let isWarning: Bool
        static func == (a: BuildError, b: BuildError) -> Bool { a.id == b.id }
    }

    enum Phase: Equatable {
        case idle
        case building(started: Date)
        case installing
        case succeeded(device: String, seconds: Int)
        case failed(errors: Int, seconds: Int)
        case cancelled
    }

    /// The `.xcodeproj` or `.xcworkspace` directly under `root`, if any.
    static func container(in root: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        if let ws = items.first(where: { $0.pathExtension == "xcworkspace" && !$0.lastPathComponent.hasPrefix("project") }) { return ws }
        return items.first { $0.pathExtension == "xcodeproj" }
    }

    private var process: Process?
    private(set) var log = ""

    /// Runs the full cycle, calling `onPhase` as it moves along and
    /// `onErrors` when the compiler reports problems. `onOutput` gets every
    /// line for the Terminal tab.
    func run(root: URL, container: URL, onPhase: @escaping (Phase) -> Void,
             onErrors: @escaping ([BuildError]) -> Void,
             onOutput: @escaping (String) -> Void) async {
        let started = Date()
        onPhase(.building(started: started))
        log = ""
        let scheme = await scheme(for: container)
        guard let scheme else {
            onErrors([BuildError(file: container.lastPathComponent, line: 0, message: "Couldn't read a scheme from \(container.lastPathComponent).", isWarning: false)])
            onPhase(.failed(errors: 1, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        let device = await simulator()
        guard let device else {
            onErrors([BuildError(file: "", line: 0, message: "No iPhone simulator found — open Xcode ▸ Settings ▸ Platforms and add one.", isWarning: false)])
            onPhase(.failed(errors: 1, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        let derived = FileManager.default.temporaryDirectory.appendingPathComponent("peeky-derived-\(scheme)", isDirectory: true)
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        var args = ["xcodebuild", flag, container.path, "-scheme", scheme,
                    "-destination", "platform=iOS Simulator,id=\(device.udid)",
                    "-derivedDataPath", derived.path,
                    "-configuration", "Debug", "build",
                    "CODE_SIGNING_ALLOWED=NO", "-quiet"]
        let buildStatus = await stream(args, cwd: root, onOutput: onOutput)
        var errors = Self.parseErrors(log, root: root)
        if buildStatus != 0 || errors.contains(where: { !$0.isWarning }) {
            if !errors.contains(where: { !$0.isWarning }) {
                errors.append(BuildError(file: "", line: 0, message: Self.lastMeaningfulLine(log) ?? "xcodebuild failed (exit \(buildStatus)).", isWarning: false))
            }
            onErrors(errors)
            onPhase(.failed(errors: errors.filter { !$0.isWarning }.count, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        onErrors(errors)  // warnings only
        onPhase(.installing)

        // Find the built .app and its bundle id.
        let products = derived.appendingPathComponent("Build/Products/Debug-iphonesimulator")
        guard let app = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            onErrors([BuildError(file: "", line: 0, message: "Build finished but no .app was produced in \(products.path).", isWarning: false)])
            onPhase(.failed(errors: 1, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        let bundleID = plist?["CFBundleIdentifier"] as? String ?? scheme

        if device.state != "Booted" {
            _ = await stream(["xcrun", "simctl", "boot", device.udid], cwd: root, onOutput: onOutput)
        }
        _ = await stream(["open", "-a", "Simulator"], cwd: root, onOutput: onOutput)
        _ = await stream(["xcrun", "simctl", "bootstatus", device.udid, "-b"], cwd: root, onOutput: onOutput)
        args = ["xcrun", "simctl", "install", device.udid, app.path]
        guard await stream(args, cwd: root, onOutput: onOutput) == 0 else {
            onErrors([BuildError(file: "", line: 0, message: Self.lastMeaningfulLine(log) ?? "simctl install failed.", isWarning: false)])
            onPhase(.failed(errors: 1, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        _ = await stream(["xcrun", "simctl", "terminate", device.udid, bundleID], cwd: root, onOutput: { _ in })
        guard await stream(["xcrun", "simctl", "launch", device.udid, bundleID], cwd: root, onOutput: onOutput) == 0 else {
            onErrors([BuildError(file: "", line: 0, message: Self.lastMeaningfulLine(log) ?? "simctl launch failed.", isWarning: false)])
            onPhase(.failed(errors: 1, seconds: Int(Date().timeIntervalSince(started))))
            return
        }
        onPhase(.succeeded(device: device.name, seconds: Int(Date().timeIntervalSince(started))))
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - Pieces

    private func scheme(for container: URL) async -> String? {
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let out = await capture(["xcodebuild", flag, container.path, "-list", "-json"], cwd: container.deletingLastPathComponent())
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (json["project"] ?? json["workspace"]) as? [String: Any],
              let schemes = inner["schemes"] as? [String] else { return nil }
        // Prefer a scheme named like the project; skip test/UI-test schemes.
        let base = container.deletingPathExtension().lastPathComponent
        return schemes.first { $0 == base } ?? schemes.first { !$0.lowercased().contains("test") } ?? schemes.first
    }

    private struct Device { let name: String; let udid: String; let state: String }

    /// A booted iPhone if there is one, else the newest available iPhone.
    private func simulator() async -> Device? {
        let out = await capture(["xcrun", "simctl", "list", "devices", "available", "-j"], cwd: nil)
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return nil }
        var phones: [Device] = []
        for (runtime, devices) in runtimes.sorted(by: { $0.key > $1.key }) where runtime.contains("iOS") {
            for d in devices {
                guard let name = d["name"] as? String, name.hasPrefix("iPhone"),
                      let udid = d["udid"] as? String, let state = d["state"] as? String else { continue }
                phones.append(Device(name: name, udid: udid, state: state))
            }
        }
        if let booted = phones.first(where: { $0.state == "Booted" }) { return booted }
        // Newest runtime first (sorted above); within it prefer a plain "iPhone N".
        return phones.first { $0.name.range(of: #"^iPhone \d+$"#, options: .regularExpression) != nil } ?? phones.first
    }

    /// Runs a command, streaming its lines and appending to `log`.
    private func stream(_ args: [String], cwd: URL?, onOutput: @escaping (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        process = p
        return await withCheckedContinuation { cont in
            var buffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<nl], as: UTF8.self)
                    buffer.removeSubrange(...nl)
                    Task { @MainActor in
                        self.log += line + "\n"
                        onOutput(line)
                    }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                let tail = String(decoding: buffer + rest, as: UTF8.self)
                Task { @MainActor in
                    if !tail.isEmpty { self.log += tail + "\n"; onOutput(tail) }
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            do { try p.run() } catch {
                Task { @MainActor in
                    self.log += "\(error.localizedDescription)\n"
                    onOutput(error.localizedDescription)
                    cont.resume(returning: 127)
                }
            }
        }
    }

    private func capture(_ args: [String], cwd: URL?) async -> String {
        var out = ""
        _ = await stream(args, cwd: cwd) { out += $0 + "\n" }
        return out
    }

    // MARK: - Parsing

    /// `path:line:col: error: message` — clang and swiftc both print this.
    private static let diagnostic = try! NSRegularExpression(
        pattern: #"^(/[^:\n]+):(\d+):(?:\d+:)?\s*(error|warning):\s*(.+)$"#, options: .anchorsMatchLines)

    static func parseErrors(_ log: String, root: URL) -> [BuildError] {
        var seen = Set<String>()
        var out: [BuildError] = []
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for m in diagnostic.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
            guard let fileR = Range(m.range(at: 1), in: log), let lineR = Range(m.range(at: 2), in: log),
                  let kindR = Range(m.range(at: 3), in: log), let msgR = Range(m.range(at: 4), in: log) else { continue }
            var file = String(log[fileR])
            if file.hasPrefix(rootPath) { file.removeFirst(rootPath.count) }
            let line = Int(log[lineR]) ?? 0
            let message = String(log[msgR]).trimmingCharacters(in: .whitespaces)
            let key = "\(file):\(line):\(message)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(BuildError(file: file, line: line, message: message, isWarning: log[kindR] == "warning"))
        }
        // Linker / project-level errors have no file:line.
        let bare = try! NSRegularExpression(pattern: #"^(?:xcodebuild: )?error: (.+)$"#, options: .anchorsMatchLines)
        for m in bare.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
            guard let r = Range(m.range(at: 1), in: log) else { continue }
            let message = String(log[r])
            guard !seen.contains(message) else { continue }
            seen.insert(message)
            out.append(BuildError(file: "", line: 0, message: message, isWarning: false))
        }
        return out.sorted { !$0.isWarning && $1.isWarning }
    }

    static func lastMeaningfulLine(_ log: String) -> String? {
        log.split(separator: "\n").reversed().map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("**") && !$0.contains("BUILD FAILED") }
    }
}
