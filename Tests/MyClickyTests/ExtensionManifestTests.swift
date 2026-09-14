import XCTest
@testable import MyClicky

final class ExtensionManifestTests: XCTestCase {
    static let full = """
    {
      "id": "com.example.kitchen-sink",
      "name": "Kitchen Sink",
      "version": "1.2.3",
      "description": "Everything at once",
      "author": "Peeky",
      "apiVersion": 1,
      "contributes": {
        "languages": [
          { "id": "ruby", "extensions": ["rb", "rake"], "base": "python",
            "keywords": ["def", "end"], "lineComment": "#",
            "rules": [ { "pattern": ":[a-z_]+", "token": "variable" } ] }
        ],
        "themes": [
          { "id": "solarized", "name": "Solarized", "colors": { "plain": "#839496", "background": "#002B36", "keyword": "#859900FF" } }
        ],
        "formatters": [
          { "id": "prettier", "name": "Prettier", "extensions": ["js"], "command": "npx",
            "args": ["prettier", "--stdin-filepath", "${file}"], "stdin": true }
        ],
        "linters": [
          { "id": "eslint", "name": "ESLint", "extensions": ["js"], "command": "npx",
            "args": ["eslint", "-f", "unix", "${file}"],
            "pattern": "^(?<file>[^:]+):(?<line>\\\\d+):(?<col>\\\\d+): (?<message>.*?) \\\\[(?<severity>\\\\w+)/" }
        ],
        "actions": [
          { "verb": "toggle_dark_mode", "description": "Switch macOS dark mode", "script": "scripts/dark.sh",
            "runner": "shell", "note": "Toggling dark mode…" },
          { "verb": "say_hello", "description": "Greets", "script": "scripts/hello.js", "runner": "javascript",
            "params": [ { "name": "name", "required": true } ], "irreversible": true }
        ]
      }
    }
    """

    func testDecodesEveryContributionKind() throws {
        let manifest = try ExtensionManifest.decode(Data(Self.full.utf8))
        XCTAssertEqual(manifest.id, "com.example.kitchen-sink")
        XCTAssertEqual(manifest.contributes?.languages?.first?.extensions, ["rb", "rake"])
        XCTAssertEqual(manifest.contributes?.themes?.first?.colors["background"], "#002B36")
        XCTAssertEqual(manifest.contributes?.formatters?.first?.stdin, true)
        XCTAssertEqual(manifest.contributes?.linters?.first?.id, "eslint")
        XCTAssertEqual(manifest.contributes?.actions?.map(\.verb), ["toggle_dark_mode", "say_hello"])
        XCTAssertEqual(manifest.scriptPaths, ["scripts/dark.sh", "scripts/hello.js"])
    }

    func testMinimalManifestIsValid() throws {
        let manifest = try ExtensionManifest.decode(Data(#"{"id":"tiny","name":"Tiny","version":"0.1"}"#.utf8))
        XCTAssertNil(manifest.contributes)
        XCTAssertTrue(manifest.scriptPaths.isEmpty)
    }

    func testRejectsBadID() {
        XCTAssertThrowsError(try ExtensionManifest.decode(Data(#"{"id":"has space","name":"x","version":"1"}"#.utf8))) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .invalidID("has space"))
        }
    }

    func testRejectsNewerAPIVersion() {
        XCTAssertThrowsError(try ExtensionManifest.decode(Data(#"{"id":"a","name":"x","version":"1","apiVersion":99}"#.utf8))) { error in
            XCTAssertEqual(error as? ExtensionManifestError, .unsupportedAPIVersion(99))
        }
    }

    func testRejectsBadVerbDuplicateVerbAndBadRunner() {
        func manifest(_ actions: String) -> Data {
            Data(#"{"id":"a","name":"x","version":"1","contributes":{"actions":[\#(actions)]}}"#.utf8)
        }
        XCTAssertThrowsError(try ExtensionManifest.decode(manifest(#"{"verb":"Bad-Verb","description":"d","script":"s.sh"}"#))) {
            XCTAssertEqual($0 as? ExtensionManifestError, .badVerb("Bad-Verb"))
        }
        XCTAssertThrowsError(try ExtensionManifest.decode(manifest(
            #"{"verb":"go","description":"d","script":"s.sh"},{"verb":"go","description":"d","script":"t.sh"}"#))) {
            XCTAssertEqual($0 as? ExtensionManifestError, .duplicateVerb("go"))
        }
        XCTAssertThrowsError(try ExtensionManifest.decode(manifest(#"{"verb":"go","description":"d","script":"s.sh","runner":"python"}"#))) {
            XCTAssertEqual($0 as? ExtensionManifestError, .badRunner("python"))
        }
    }

    func testRejectsBadRegexAndBadColour() {
        let linter = #"{"id":"a","name":"x","version":"1","contributes":{"linters":[{"id":"l","name":"L","extensions":["js"],"command":"x","pattern":"(unclosed"}]}}"#
        XCTAssertThrowsError(try ExtensionManifest.decode(Data(linter.utf8))) { error in
            guard case .badRegex(let what, _)? = error as? ExtensionManifestError else { return XCTFail("\(error)") }
            XCTAssertEqual(what, "Linter l")
        }
        let theme = #"{"id":"a","name":"x","version":"1","contributes":{"themes":[{"id":"t","name":"T","colors":{"plain":"red"}}]}}"#
        XCTAssertThrowsError(try ExtensionManifest.decode(Data(theme.utf8))) {
            XCTAssertEqual($0 as? ExtensionManifestError, .badColor("t.plain", "red"))
        }
    }

    func testMissingRequiredKeyIsExplained() {
        XCTAssertThrowsError(try ExtensionManifest.decode(Data(#"{"id":"a","version":"1"}"#.utf8))) { error in
            guard case .invalidJSON(let detail)? = error as? ExtensionManifestError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("name"), detail)
        }
    }
}

@MainActor
final class ExtensionManagerTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PeekyExtTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: ExtensionManager.disabledKey)
        UserDefaults.standard.removeObject(forKey: ExtensionManager.themeKey)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: ExtensionManager.disabledKey)
        UserDefaults.standard.removeObject(forKey: ExtensionManager.themeKey)
        ExtensionRegistry.current = .empty
        SyntaxHighlighter.invalidateCustomLanguages()
        super.tearDown()
    }

    @discardableResult
    private func write(_ folder: String, manifest: String, scripts: [String: String] = [:], in base: URL? = nil) throws -> URL {
        let dir = (base ?? root).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for (path, body) in scripts {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    func testReloadFindsValidBrokenAndScriptlessExtensions() throws {
        try write("good", manifest: #"{"id":"good","name":"Good","version":"1","contributes":{"actions":[{"verb":"hi","description":"d","script":"hi.sh"}]}}"#,
                  scripts: ["hi.sh": "#!/bin/zsh\necho hi"])
        try write("broken", manifest: "{ not json")
        try write("noscript", manifest: #"{"id":"noscript","name":"N","version":"1","contributes":{"actions":[{"verb":"go","description":"d","script":"missing.sh"}]}}"#)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let manager = ExtensionManager(root: root)
        manager.reload()

        XCTAssertEqual(manager.installed.map(\.id), ["broken", "empty", "good", "noscript"])
        XCTAssertTrue(manager.installed[2].isActive)
        XCTAssertNotNil(manager.installed[0].error)
        XCTAssertEqual(manager.installed[1].error, ExtensionManifestError.missingManifest.localizedDescription)
        XCTAssertEqual(manager.installed[3].error, ExtensionManifestError.missingScript("missing.sh").localizedDescription)
        XCTAssertEqual(manager.registry.verbs, ["hi"])
        XCTAssertEqual(ExtensionRegistry.current.verbs, ["hi"])
    }

    func testDisablingDropsContributionsAndPersists() throws {
        try write("a", manifest: #"{"id":"a","name":"A","version":"1","contributes":{"themes":[{"id":"t","name":"T","colors":{}}]}}"#)
        let manager = ExtensionManager(root: root)
        manager.reload()
        XCTAssertEqual(manager.registry.themes.count, 1)

        manager.setEnabled(false, id: "a")
        XCTAssertTrue(manager.registry.themes.isEmpty)
        XCTAssertFalse(manager.installed[0].enabled)

        let again = ExtensionManager(root: root)
        again.reload()
        XCTAssertFalse(again.installed[0].enabled, "disabled set should survive a new manager")
    }

    func testFirstExtensionKeepsAVerbOnCollision() throws {
        try write("one", manifest: #"{"id":"one","name":"1","version":"1","contributes":{"actions":[{"verb":"shared","description":"first","script":"s.sh"}]}}"#, scripts: ["s.sh": ""])
        try write("two", manifest: #"{"id":"two","name":"2","version":"1","contributes":{"actions":[{"verb":"shared","description":"second","script":"s.sh"},{"verb":"own","description":"o","script":"s.sh"}]}}"#, scripts: ["s.sh": ""])
        let manager = ExtensionManager(root: root)
        manager.reload()
        XCTAssertEqual(manager.registry.action(verb: "shared")?.extensionID, "one")
        XCTAssertEqual(manager.registry.verbs, ["shared", "own"])
    }

    func testThemeSelectionClearsWhenItsExtensionGoesAway() throws {
        try write("th", manifest: ##"{"id":"th","name":"Th","version":"1","contributes":{"themes":[{"id":"night","name":"Night","colors":{"plain":"#FFFFFF"}}]}}"##)
        let manager = ExtensionManager(root: root)
        manager.reload()
        manager.themeID = "night"
        XCTAssertEqual(UserDefaults.standard.string(forKey: ExtensionManager.themeKey), "night")

        manager.setEnabled(false, id: "th")
        XCTAssertNil(manager.themeID)
    }

    func testInstallFromFolderCopiesUnderManifestIDAndRefusesDuplicates() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PeekyStaging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = try write("whatever-folder-name", manifest: #"{"id":"com.test.installed","name":"I","version":"2.0"}"#, in: staging)

        let manager = ExtensionManager(root: root)
        let installed = try manager.install(folder: source)
        XCTAssertEqual(installed.id, "com.test.installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("com.test.installed/manifest.json").path))
        XCTAssertEqual(manager.installed.count, 1)

        XCTAssertThrowsError(try manager.install(folder: source))
    }

    func testInstallRefusesNonExtensionFolder() throws {
        let junk = root.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        let manager = ExtensionManager(root: root.appendingPathComponent("store"))
        XCTAssertThrowsError(try manager.install(folder: junk))
    }

    func testRunActionReturnsLastStdoutLineAndFailsOnNonZero() async throws {
        try write("run", manifest: #"{"id":"run","name":"R","version":"1","contributes":{"actions":[{"verb":"echo_name","description":"d","script":"echo.sh","params":[{"name":"name"}]},{"verb":"fail","description":"d","script":"fail.sh"}]}}"#,
                  scripts: ["echo.sh": "#!/bin/zsh\necho \"progress\"\necho \"hello $PEEKY_PARAM_NAME / $1 / $PEEKY_VERB\"",
                            "fail.sh": "#!/bin/zsh\necho 'reason: nope' >&2\nexit 3"])
        let manager = ExtensionManager(root: root)
        manager.reload()

        let out = try await manager.runAction(verb: "echo_name", params: ["name": "Ada"])
        XCTAssertEqual(out, "hello Ada / Ada / echo_name")

        do {
            _ = try await manager.runAction(verb: "fail", params: [:])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "reason: nope")
        }

        do {
            _ = try await manager.runAction(verb: "unknown", params: [:])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ExtensionScriptRunner.Failure, .notFound("unknown"))
        }
    }

    func testCustomLanguageAndThemeReachTheHighlighter() throws {
        try write("lang", manifest: ##"{"id":"lang","name":"L","version":"1","contributes":{"languages":[{"id":"ruby","extensions":["rb"],"base":"python","keywords":["begin"]}],"themes":[{"id":"t","name":"T","colors":{"plain":"#112233","background":"#000000"}}]}}"##)
        let manager = ExtensionManager(root: root)
        manager.reload()

        XCTAssertEqual(SyntaxHighlighter.language(for: "lib/app.rb"), .custom("ruby"))
        XCTAssertEqual(SyntaxHighlighter.language(for: "lib/app.py"), .python)
        XCTAssertFalse(SyntaxHighlighter.rules(for: .custom("ruby")).isEmpty)

        let theme = try XCTUnwrap(manager.registry.theme(id: "t").flatMap { SyntaxHighlighter.Theme(manifest: $0.item) })
        XCTAssertEqual(theme.plain, NSColor(hex: "#112233"))
        XCTAssertEqual(theme.color(.keyword), SyntaxHighlighter.Theme.darkModern.color(.keyword), "missing tokens fall back")
    }

    func testShippedExampleExtensionLoadsCleanly() async throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/extensions/hello-peeky")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: example.appendingPathComponent("manifest.json").path))

        let manager = ExtensionManager(root: root)
        let loaded = try manager.install(folder: example)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.id, "hello-peeky")
        XCTAssertEqual(manager.registry.verbs, ["say_hello"])
        XCTAssertNotNil(manager.registry.theme(id: "hello-warm"))
        XCTAssertEqual(SyntaxHighlighter.language(for: "demo.pk"), .custom("peekyscript"))
        XCTAssertFalse(manager.registry.linters(forPath: "demo.pk").isEmpty)

        let result = try await manager.runAction(verb: "say_hello", params: ["name": "Test"], context: [:])
        XCTAssertTrue(result.hasPrefix("Hello, Test!"), result)
    }
}
