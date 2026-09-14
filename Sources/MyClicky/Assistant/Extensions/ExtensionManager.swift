import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "extensions")

/// One extension folder as found on disk. `error` is set when the manifest
/// didn't load — the row still shows so the user can see why and fix it.
struct LoadedExtension: Identifiable, Equatable {
    let folder: URL
    let manifest: ExtensionManifest?
    let error: String?
    var enabled: Bool

    var id: String { manifest?.id ?? folder.lastPathComponent }
    var name: String { manifest?.name ?? folder.lastPathComponent }
    var version: String { manifest?.version ?? "—" }
    var isActive: Bool { enabled && manifest != nil && error == nil }

    var summary: String {
        guard let c = manifest?.contributes else { return "" }
        var parts: [String] = []
        func add(_ n: Int?, _ word: String) { if let n, n > 0 { parts.append("\(n) \(word)\(n == 1 ? "" : "s")") } }
        add(c.languages?.count, "language")
        add(c.themes?.count, "theme")
        add(c.formatters?.count, "formatter")
        add(c.linters?.count, "linter")
        add(c.actions?.count, "action")
        return parts.joined(separator: " · ")
    }
}

/// Everything the active extensions contribute, flattened for lookups. A
/// value type so the highlighter and the planner can each hold a snapshot
/// without caring when the manager next reloads.
struct ExtensionRegistry: Equatable, Sendable {
    struct Owned<T: Equatable & Sendable>: Equatable, Sendable {
        let extensionID: String
        let folder: URL
        let item: T
    }

    var languages: [Owned<ExtensionManifest.Language>] = []
    var themes: [Owned<ExtensionManifest.Theme>] = []
    var formatters: [Owned<ExtensionManifest.Formatter>] = []
    var linters: [Owned<ExtensionManifest.Linter>] = []
    var actions: [Owned<ExtensionManifest.Action>] = []

    static let empty = ExtensionRegistry()

    init() {}

    init(extensions: [LoadedExtension]) {
        var verbs = Set<String>()
        for ext in extensions where ext.isActive {
            guard let manifest = ext.manifest, let c = manifest.contributes else { continue }
            func own<T>(_ item: T) -> Owned<T> { Owned(extensionID: manifest.id, folder: ext.folder, item: item) }
            languages += (c.languages ?? []).map(own)
            themes += (c.themes ?? []).map(own)
            formatters += (c.formatters ?? []).map(own)
            linters += (c.linters ?? []).map(own)
            // Verbs are global to the planner; the first extension to claim
            // one keeps it, so a later install can't hijack a working verb.
            for action in c.actions ?? [] where verbs.insert(action.verb).inserted {
                actions.append(own(action))
            }
        }
    }

    func language(forExtension ext: String) -> Owned<ExtensionManifest.Language>? {
        let lower = ext.lowercased()
        return languages.last { $0.item.extensions.contains { $0.lowercased() == lower } }
    }

    func theme(id: String) -> Owned<ExtensionManifest.Theme>? { themes.first { $0.item.id == id } }

    func formatters(forPath path: String) -> [Owned<ExtensionManifest.Formatter>] {
        let ext = (path as NSString).pathExtension.lowercased()
        return formatters.filter { $0.item.extensions.contains { $0.lowercased() == ext } }
    }

    func linters(forPath path: String) -> [Owned<ExtensionManifest.Linter>] {
        let ext = (path as NSString).pathExtension.lowercased()
        return linters.filter { $0.item.extensions.contains { $0.lowercased() == ext } }
    }

    func action(verb: String) -> Owned<ExtensionManifest.Action>? { actions.first { $0.item.verb == verb } }

    var verbs: Set<String> { Set(actions.map(\.item.verb)) }

    /// Process-wide snapshot for code that can't reach the manager (the
    /// highlighter runs inside AppKit text storage callbacks).
    static var current: ExtensionRegistry {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = ExtensionRegistry()
}

/// Finds, validates, switches on and off, installs and removes extensions.
/// Extensions live one folder each under
/// `~/Library/Application Support/MyClicky/Extensions/`; dropping a folder
/// there and pressing ↻ is a complete install.
@MainActor
final class ExtensionManager: ObservableObject {
    @Published private(set) var installed: [LoadedExtension] = []
    @Published private(set) var registry = ExtensionRegistry.empty
    @Published private(set) var busy: String?
    @Published var lastMessage: String?
    /// Selected code theme; `nil` is the built-in Dark Modern.
    @Published var themeID: String? = UserDefaults.standard.string(forKey: ExtensionManager.themeKey) {
        didSet {
            UserDefaults.standard.set(themeID, forKey: Self.themeKey)
            onThemeChanged?()
        }
    }
    /// Fired after every reload so the planner prompt, the highlighter and
    /// the UI can pick up the new registry.
    var onRegistryChanged: ((ExtensionRegistry) -> Void)?
    var onThemeChanged: (() -> Void)?

    static let themeKey = "extensionsThemeID"
    static let disabledKey = "extensionsDisabled"

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyClicky/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.disabledKey) }
    }

    // MARK: Loading

    /// Re-reads every folder under `root`. Cheap enough to call after any
    /// change; this is the "dynamic loading" — no relaunch, ever.
    func reload() {
        let disabled = self.disabled
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        var loaded: [LoadedExtension] = []
        for folder in folders.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            loaded.append(Self.load(folder: folder, disabled: disabled))
        }
        installed = loaded
        registry = ExtensionRegistry(extensions: loaded)
        ExtensionRegistry.current = registry
        SyntaxHighlighter.invalidateCustomLanguages()
        if let themeID, registry.theme(id: themeID) == nil {
            // The theme's extension went away or was switched off.
            self.themeID = nil
        } else {
            onThemeChanged?()
        }
        onRegistryChanged?(registry)
        log.notice("loaded \(loaded.count) extension(s), \(self.registry.actions.count) verb(s)")
    }

    nonisolated static func load(folder: URL, disabled: Set<String>) -> LoadedExtension {
        let manifestURL = folder.appendingPathComponent(ExtensionManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return LoadedExtension(folder: folder, manifest: nil,
                                   error: ExtensionManifestError.missingManifest.localizedDescription, enabled: false)
        }
        do {
            let manifest = try ExtensionManifest.decode(data)
            for script in manifest.scriptPaths {
                let url = folder.appendingPathComponent(script).standardizedFileURL
                guard url.path.hasPrefix(folder.standardizedFileURL.path),
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw ExtensionManifestError.missingScript(script)
                }
            }
            return LoadedExtension(folder: folder, manifest: manifest, error: nil, enabled: !disabled.contains(manifest.id))
        } catch {
            return LoadedExtension(folder: folder, manifest: nil, error: error.localizedDescription, enabled: false)
        }
    }

    func setEnabled(_ enabled: Bool, id: String) {
        var set = disabled
        if enabled { set.remove(id) } else { set.insert(id) }
        disabled = set
        reload()
    }

    func reveal(_ ext: LoadedExtension) {
        NSWorkspace.shared.activateFileViewerSelecting([ext.folder])
    }

    func revealRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: Install / uninstall

    enum InstallError: LocalizedError {
        case gitMissing
        case cloneFailed(String)
        case alreadyInstalled(String)
        case notAnExtension(String)

        var errorDescription: String? {
            switch self {
            case .gitMissing: return "git isn't installed — install Xcode's command line tools first."
            case .cloneFailed(let detail): return detail.isEmpty ? "git clone failed." : detail
            case .alreadyInstalled(let id): return "“\(id)” is already installed — remove it first to reinstall."
            case .notAnExtension(let detail): return detail
            }
        }
    }

    /// `git clone --depth 1` into a temp folder, validate, then move into
    /// place under the manifest's id. Nothing lands in `root` until it's
    /// known to be a real extension.
    func install(gitURL: String, ref: String? = nil) async throws -> LoadedExtension {
        guard busy == nil else { throw InstallError.cloneFailed("Another install is running.") }
        busy = "Cloning \(gitURL)…"
        defer { busy = nil }
        guard let git = ExtensionScriptRunner.resolve(command: "git", cwd: root) else { throw InstallError.gitMissing }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("peeky-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        var args = ["clone", "--depth", "1", "--quiet"]
        if let ref, !ref.isEmpty { args += ["--branch", ref] }
        args += [gitURL, temp.path]
        let result = try await ExtensionScriptRunner.run(.init(executable: git, arguments: args, currentDirectory: root,
                                                               environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: 120))
        guard result.status == 0 else {
            throw InstallError.cloneFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? FileManager.default.removeItem(at: temp.appendingPathComponent(".git"))
        return try adopt(folder: temp)
    }

    /// Installs a folder already on this Mac (drag-and-drop, or a checkout).
    func install(folder: URL) throws -> LoadedExtension {
        try adopt(folder: folder)
    }

    private func adopt(folder: URL) throws -> LoadedExtension {
        let probe = Self.load(folder: folder, disabled: [])
        guard let manifest = probe.manifest else { throw InstallError.notAnExtension(probe.error ?? "Not an extension.") }
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw InstallError.alreadyInstalled(manifest.id) }
        try FileManager.default.copyItem(at: folder, to: destination)
        var set = disabled
        set.remove(manifest.id)
        disabled = set
        reload()
        lastMessage = "Installed \(manifest.name) \(manifest.version)"
        log.notice("installed \(manifest.id, privacy: .public) \(manifest.version, privacy: .public)")
        return installed.first { $0.id == manifest.id } ?? probe
    }

    func uninstall(_ ext: LoadedExtension) throws {
        try FileManager.default.trashItem(at: ext.folder, resultingItemURL: nil)
        var set = disabled
        set.remove(ext.id)
        disabled = set
        reload()
        lastMessage = "Removed \(ext.name) (moved to Trash)"
        log.notice("uninstalled \(ext.id, privacy: .public)")
    }

    // MARK: Running actions

    /// Runs an extension verb with the given params. Returns the script's
    /// first stdout line on success; throws with the script's stderr (or
    /// the runner's reason) on failure.
    func runAction(verb: String, params: [String: String], context: [String: String] = [:]) async throws -> String {
        guard let owned = registry.action(verb: verb) else {
            throw ExtensionScriptRunner.Failure.notFound(verb)
        }
        let result = try await ExtensionScriptRunner.runAction(owned.item, in: owned.folder, extensionID: owned.extensionID,
                                                                params: params, context: context)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            let reason = (err.isEmpty ? out : err).split(whereSeparator: \.isNewline).first.map(String.init)
            throw ExtensionScriptRunner.Failure.launch(reason ?? "\(verb) failed (exit \(result.status)).")
        }
        return out.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Done."
    }
}
