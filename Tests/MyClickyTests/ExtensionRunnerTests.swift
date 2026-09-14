import XCTest
@testable import MyClicky

final class ExtensionScriptRunnerTests: XCTestCase {
    func testParseFindingsReadsNamedGroupsAndSeverities() {
        let output = """
        src/app.js:12:5: Unexpected console statement [warning/no-console]
        src/app.js:40:1: 'x' is not defined [error/no-undef]
        src/app.js:41:1: something [info/whatever]
        noise line
        src/app.js:12:5: Unexpected console statement [warning/no-console]
        """
        let pattern = #"^(?<file>[^:]+):(?<line>\d+):(?<col>\d+): (?<message>.*?) \[(?<severity>\w+)/"#
        let findings = ExtensionScriptRunner.parseFindings(output, pattern: pattern, source: "ESLint")
        XCTAssertEqual(findings.count, 3, "duplicates collapse")
        XCTAssertEqual(findings[0].line, 12)
        XCTAssertEqual(findings[0].column, 5)
        XCTAssertEqual(findings[0].severity, 2)
        XCTAssertEqual(findings[0].message, "Unexpected console statement")
        XCTAssertEqual(findings[1].severity, 1)
        XCTAssertEqual(findings[2].severity, 3)
        XCTAssertEqual(findings[0].source, "ESLint")
    }

    func testParseFindingsWithoutSeverityDefaultsToWarning() {
        let findings = ExtensionScriptRunner.parseFindings("7: trailing whitespace", pattern: #"^(?<line>\d+): (?<message>.*)$"#, source: "x")
        XCTAssertEqual(findings.map(\.severity), [2])
        XCTAssertEqual(findings.map(\.column), [0])
    }

    func testSubstituteFillsEveryPlaceholder() {
        let args = ExtensionScriptRunner.substitute(["${file}", "--root=${project}", "${name}", "${dir}", "${ext}/cfg"],
                                                    file: URL(fileURLWithPath: "/p/src/a.js"),
                                                    project: URL(fileURLWithPath: "/p"),
                                                    extensionDir: URL(fileURLWithPath: "/e"))
        XCTAssertEqual(args, ["/p/src/a.js", "--root=/p", "a.js", "/p/src", "/e/cfg"])
    }

    func testRunPipesStdinAndEnvironment() async throws {
        let result = try await ExtensionScriptRunner.run(.init(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", "read line; echo \"$line:$PEEKY_TEST\""],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: ["PEEKY_TEST": "ok"], stdin: "in\n", timeout: 10))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "in:ok")
    }

    func testRunTimesOut() async {
        do {
            _ = try await ExtensionScriptRunner.run(.init(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                currentDirectory: FileManager.default.temporaryDirectory, timeout: 0.3))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ExtensionScriptRunner.Failure, .timedOut(0.3))
        }
    }

    func testStdinFormatterReturnsStdoutWithoutTouchingDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PeekyFmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let formatter = ExtensionManifest.Formatter(id: "up", name: "Up", extensions: ["txt"], command: "/usr/bin/tr",
                                                    args: ["a-z", "A-Z"], stdin: true, timeout: 10)
        let result = try await ExtensionScriptRunner.format(formatter, text: "hello", file: file, project: dir, extensionDir: dir)
        XCTAssertEqual(result.text, "HELLO")
        XCTAssertTrue(result.changed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testInPlaceFormatterWritesThenReadsBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PeekyFmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        let formatter = ExtensionManifest.Formatter(id: "sh", name: "Sh", extensions: ["txt"], command: "/bin/zsh",
                                                    args: ["-c", "printf formatted > \"${file}\""], stdin: false, timeout: 10)
        let result = try await ExtensionScriptRunner.format(formatter, text: "draft", file: file, project: dir, extensionDir: dir)
        XCTAssertEqual(result.text, "formatted")
        XCTAssertTrue(result.changed)
    }

    func testMissingCommandIsReportedAsNotFound() async {
        let formatter = ExtensionManifest.Formatter(id: "x", name: "X", extensions: ["txt"], command: "definitely-not-a-real-tool-xyz")
        do {
            _ = try await ExtensionScriptRunner.format(formatter, text: "", file: URL(fileURLWithPath: "/tmp/a.txt"),
                                                       project: URL(fileURLWithPath: "/tmp"), extensionDir: URL(fileURLWithPath: "/tmp"))
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? ExtensionScriptRunner.Failure, .notFound("definitely-not-a-real-tool-xyz"))
        }
    }

    func testLintParsesToolOutputEvenOnNonZeroExit() async throws {
        let dir = FileManager.default.temporaryDirectory
        let linter = ExtensionManifest.Linter(id: "l", name: "L", extensions: ["txt"], command: "/bin/zsh",
                                              args: ["-c", "echo '3:1: bad thing'; exit 1"], stdin: nil,
                                              pattern: #"^(?<line>\d+):(?<col>\d+): (?<message>.*)$"#, timeout: 10)
        let findings = try await ExtensionScriptRunner.lint(linter, text: "", file: dir.appendingPathComponent("a.txt"),
                                                            project: dir, extensionDir: dir)
        XCTAssertEqual(findings.map(\.line), [3])
        XCTAssertEqual(findings.map(\.message), ["bad thing"])
    }
}

final class ExtensionMarketplaceTests: XCTestCase {
    func testDecodesCatalogAndFilters() throws {
        let json = """
        {"catalogVersion":1,"extensions":[
          {"id":"a","name":"Solarized","version":"1.0.0","description":"A theme","repo":"https://x/a.git","tags":["theme"]},
          {"id":"b","name":"Prettier","version":"2.1.0","author":"Jane","repo":"https://x/b.git","ref":"v2.1.0","tags":["formatter","js"]}
        ]}
        """
        let catalog = try ExtensionMarketplace.decode(Data(json.utf8))
        XCTAssertEqual(catalog.extensions.count, 2)
        XCTAssertEqual(catalog.extensions[1].ref, "v2.1.0")
        XCTAssertTrue(catalog.extensions[0].matches("theme"))
        XCTAssertTrue(catalog.extensions[1].matches("jane js"))
        XCTAssertFalse(catalog.extensions[0].matches("prettier"))
        XCTAssertTrue(catalog.extensions[0].matches("  "))
    }

    func testRejectsNewerCatalogVersion() {
        XCTAssertThrowsError(try ExtensionMarketplace.decode(Data(#"{"catalogVersion":7,"extensions":[]}"#.utf8)))
    }

    func testVersionCompare() {
        XCTAssertEqual(ExtensionMarketplace.compareVersions("1.10.0", "1.9.2"), .orderedDescending)
        XCTAssertEqual(ExtensionMarketplace.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(ExtensionMarketplace.compareVersions("0.9", "1"), .orderedAscending)
    }

    @MainActor
    func testUpdateDetection() {
        let entry = MarketplaceEntry(id: "a", name: "A", version: "1.1.0", repo: "r")
        let manifest = ExtensionManifest(id: "a", name: "A", version: "1.0.0")
        let installed = LoadedExtension(folder: URL(fileURLWithPath: "/tmp/a"), manifest: manifest, error: nil, enabled: true)
        XCTAssertTrue(ExtensionMarketplace.isUpdate(entry, installed: installed))
        XCTAssertFalse(ExtensionMarketplace.isUpdate(entry, installed: nil))
    }
}

final class ExtensionPlannerIntegrationTests: XCTestCase {
    private func owned(_ action: ExtensionManifest.Action) -> ExtensionRegistry.Owned<ExtensionManifest.Action> {
        .init(extensionID: "ext", folder: URL(fileURLWithPath: "/tmp/ext"), item: action)
    }

    func testExtensionVerbsJoinTheAllowList() {
        var callbacks = ActionPlanner.Callbacks()
        XCTAssertFalse(ActionPlanner.allowedVerbs(callbacks).contains("toggle_dark_mode"))
        callbacks.extensionActions = [owned(.init(verb: "toggle_dark_mode", description: "d", script: "s.sh"))]
        XCTAssertTrue(ActionPlanner.allowedVerbs(callbacks).contains("toggle_dark_mode"))
        XCTAssertTrue(ActionPlanner.allowedVerbs(callbacks).contains("click"))
    }

    func testPromptDescribesVerbsParamsAndSkipsBuiltinCollisions() {
        let actions = [
            owned(.init(verb: "say_hello", description: "Greets someone.", params: [.init(name: "name", description: "who", required: true)],
                        script: "s.sh", irreversible: true)),
            owned(.init(verb: "click", description: "should not appear", script: "s.sh")),
        ]
        let prompt = ActionPlanner.extensionVerbPrompt(actions)
        XCTAssertTrue(prompt.contains("- say_hello: Greets someone."))
        XCTAssertTrue(prompt.contains("\"name\" (required) — who"))
        XCTAssertTrue(prompt.contains(#"{"verb":"say_hello","params":{"name":"..."}}"#))
        XCTAssertTrue(prompt.contains("irreversible"))
        XCTAssertFalse(prompt.contains("should not appear"))
        XCTAssertEqual(ActionPlanner.extensionVerbPrompt([]), "")
    }

    func testStepDecodesParams() throws {
        let data = Data(#"{"steps":[{"verb":"say_hello","params":{"name":"Ada"},"note":"Saying hi…"}]}"#.utf8)
        let plan = try JSONDecoder().decode(ActionPlanner.Plan.self, from: data)
        XCTAssertEqual(plan.steps.first?.params, ["name": "Ada"])
    }
}

@MainActor
final class ExtensionRemoteCommandTests: XCTestCase {
    func testParsesVerbAndTabSeparatedParams() {
        let (verb, params) = RemoteControlService.parseExtensionCommand("Say_Hello\tname=Ada Lovelace\tmood=happy=very\tjunk")
        XCTAssertEqual(verb, "say_hello")
        XCTAssertEqual(params, ["name": "Ada Lovelace", "mood": "happy=very"])
    }

    func testExtCommandIsForwarded() {
        let service = RemoteControlService()
        var received: [(String, [String: String])] = []
        service.onExtension = { received.append(($0, $1)) }
        var tabs: [String] = []
        service.onTab = { tabs.append($0) }

        service.handle("EXT toggle_dark_mode")
        service.handle("EXT ")
        service.handle("TAB EXTENSIONS")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "toggle_dark_mode")
        XCTAssertEqual(tabs, ["EXTENSIONS"])
    }
}

final class SyntaxHighlighterExtensionTests: XCTestCase {
    override func tearDown() {
        SyntaxHighlighter.theme = .darkModern
        super.tearDown()
    }

    func testHexColours() {
        XCTAssertEqual(NSColor(hex: "#FF0000")?.redComponent, 1)
        XCTAssertEqual(NSColor(hex: "00FF0080")?.alphaComponent ?? 0, 0.5, accuracy: 0.01)
        XCTAssertNil(NSColor(hex: "#12"))
    }

    func testCustomGrammarColoursItsKeywordsAndComments() {
        let language = ExtensionManifest.Language(id: "toy", extensions: ["toy"], base: nil, keywords: ["let"],
                                                  control: ["when"], lineComment: ";;", blockComment: nil,
                                                  rules: [.init(pattern: "@\\w+", token: "variable")])
        let rules = SyntaxHighlighter.rules(from: language)
        let storage = NSTextStorage(string: "let @x when 42 ;; note")
        // Drive the same path highlight() uses, with explicit rules.
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.foregroundColor: SyntaxHighlighter.theme.plain], range: full)
        for rule in rules {
            rule.regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: SyntaxHighlighter.theme.color(rule.token), range: match.range(at: rule.group))
            }
        }
        func color(at i: Int) -> NSColor? { storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color(at: 0), SyntaxHighlighter.theme.color(.keyword))
        XCTAssertEqual(color(at: 4), SyntaxHighlighter.theme.color(.variable))
        XCTAssertEqual(color(at: 7), SyntaxHighlighter.theme.color(.control))
        XCTAssertEqual(color(at: 12), SyntaxHighlighter.theme.color(.number))
        XCTAssertEqual(color(at: 18), SyntaxHighlighter.theme.color(.comment))
    }

    func testHighlightUsesTheActiveTheme() {
        SyntaxHighlighter.theme = SyntaxHighlighter.Theme(id: "t", name: "T", colors: [.plain: .red, .comment: .blue], background: .black)
        let storage = NSTextStorage(string: "x // c")
        SyntaxHighlighter.highlight(storage, language: .javascript, font: .systemFont(ofSize: 12))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .red)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, .blue)
        XCTAssertEqual(SyntaxHighlighter.plain, .red)
    }
}
