import XCTest
@testable import MyClicky

final class CodeProjectBundlerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekyCodeTests-\(UUID().uuidString)/StageTimePNW")
        try write("App/AppTab.swift", "enum AppTab { case home }\n")
        try write("App/ContentView.swift", "struct ContentView {}\n")
        try write("Core/Model.py", "def f():\n    return 1\n")
        try write("Docs/notes.md", "# Notes\n")
        try write("Info.plist", "<plist/>\n")
        try write("Package.resolved", "{\"pins\": []}\n")
        try write("Assets.xcassets/Contents.json", "{}\n")
        try write("build/junk.swift", "// generated\n")
        try write("node_modules/dep/index.js", "module.exports = 1\n")
        try write(".git/HEAD", "ref: refs/heads/main\n")
        try write("logo.png", "not really a png")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: root.appendingPathComponent("bin/tool.c"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testKeepsSourceAndSkipsJunk() throws {
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let paths = project.files.map(\.path)
        XCTAssertEqual(paths, ["App/AppTab.swift", "App/ContentView.swift", "Core/Model.py", "Docs/notes.md", "Info.plist"])
        XCTAssertEqual(project.name, "StageTimePNW")
        XCTAssertFalse(project.truncated)
        // Build output, dependencies and Xcode's asset bundle are skipped by folder…
        XCTAssertEqual(project.skippedFolders, ["Assets.xcassets", "build", "node_modules"])
        // …the lock file and image by name, the NUL-laden .c as binary.
        XCTAssertTrue(project.skippedFiles.contains("bin/tool.c"))
        XCTAssertFalse(paths.contains("Package.resolved"))
        XCTAssertFalse(paths.contains("logo.png"))
    }

    func testBundleTextHasTreeThenFileHeaders() throws {
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let text = project.bundleText
        XCTAssertTrue(text.hasPrefix("Project: StageTimePNW — 5 files\nFile tree:\n  App/AppTab.swift\n"))
        XCTAssertTrue(text.contains("===== FILE: Core/Model.py =====\ndef f():\n    return 1\n"))
        XCTAssertGreaterThan(project.estimatedTokens, 0)
    }

    /// The same folder must bundle to the same bytes every time — that
    /// identity is what makes the prompt cache hit on the next question.
    func testBundleIsDeterministic() throws {
        let a = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let b = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        XCTAssertEqual(a.bundleText, b.bundleText)
    }

    func testLooseFilesRootAtCommonParent() throws {
        let urls = [root.appendingPathComponent("App/AppTab.swift"), root.appendingPathComponent("Core/Model.py")]
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: urls))
        XCTAssertEqual(project.root, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(project.files.map(\.path), ["App/AppTab.swift", "Core/Model.py"])
    }

    func testFilesGroupByFolderRootFirst() throws {
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let groups = project.filesByFolder
        XCTAssertEqual(groups.map(\.folder), ["", "App", "Core", "Docs"])
        XCTAssertEqual(groups[0].files.map(\.path), ["Info.plist"])
        XCTAssertEqual(groups[1].files.map(\.path), ["App/AppTab.swift", "App/ContentView.swift"])
        XCTAssertEqual(project.file(at: "Core/Model.py")?.text, "def f():\n    return 1\n")
        XCTAssertNil(project.file(at: "nope.swift"))
    }

    func testCompactNumbers() {
        XCTAssertEqual(CodeProject.compact(900), "900")
        XCTAssertEqual(CodeProject.compact(1_500), "1.5K")
        XCTAssertEqual(CodeProject.compact(38_400), "38K")
        XCTAssertEqual(CodeProject.compact(1_200_000), "1.2M")
    }

    func testUsageParsesCacheFields() throws {
        let json = """
        {"usage": {"input_tokens": 120, "cache_read_input_tokens": 38000, "cache_creation_input_tokens": 0, "output_tokens": 400}}
        """
        let usage = try XCTUnwrap(AnthropicService.Usage.parse(Data(json.utf8)))
        XCTAssertTrue(usage.hitCache)
        XCTAssertEqual(usage.cacheRead, 38000)
        XCTAssertEqual(usage.input, 120)
    }

    func testUsageCostUsesSonnetRates() {
        // 1M of each: $3 + $0.30 + $3.75 + $15.
        let usage = AnthropicService.Usage(input: 1_000_000, cacheRead: 1_000_000,
                                           cacheWrite: 1_000_000, output: 1_000_000)
        XCTAssertEqual(usage.costUSD, 22.05, accuracy: 0.0001)
        let cached = AnthropicService.Usage(input: 0, cacheRead: 50_000, cacheWrite: 0, output: 1_000)
        XCTAssertEqual(cached.costUSD, 0.015 + 0.015, accuracy: 0.0001)
    }

    func testAnswerSegmentsSplitProseAndFences() {
        let text = "Change this in `style.css`:\n```css\n.a { x: 1 }\n```\nReplace with:\n```css\n.a { x: 2 }\n```\nDone."
        let segments = CodeAnswerSegment.parse(text)
        XCTAssertEqual(segments, [
            .prose("Change this in `style.css`:"),
            .code(language: "css", code: ".a { x: 1 }"),
            .prose("Replace with:"),
            .code(language: "css", code: ".a { x: 2 }"),
            .prose("Done."),
        ])
        XCTAssertEqual(CodeAnswerSegment.parse("just words"), [.prose("just words")])
    }

    func testApplierReplacesFindBlock() {
        let file = "a\nb\nc\nd\n"
        let (out, outcome) = CodeBlockApplier.apply("B\nC", replacing: "b\nc", in: file)
        XCTAssertEqual(outcome, .replaced(lines: 2, atLine: 2))
        XCTAssertEqual(out, "a\nB\nC\nd\n")
        // Trailing whitespace in the file shouldn't break the match.
        let (out2, outcome2) = CodeBlockApplier.apply("X", replacing: "b\nc", in: "a\nb  \nc\nd\n")
        XCTAssertEqual(outcome2, .replaced(lines: 2, atLine: 2))
        XCTAssertEqual(out2, "a\nX\nd\n")
    }

    func testApplierRewritesWholeFileOrGivesUp() {
        let file = "body { margin: 0 }\nh1 { color: red }\n"
        let rewrite = "body { margin: 0 }\nh1 { color: blue }\np { x: 1 }\n"
        let (out, outcome) = CodeBlockApplier.apply(rewrite, replacing: nil, in: file)
        XCTAssertEqual(outcome, .rewroteFile)
        XCTAssertEqual(out, rewrite)
        let (same, lost) = CodeBlockApplier.apply("tiny", replacing: "nope", in: file)
        XCTAssertEqual(lost, .notFound)
        XCTAssertEqual(same, file)
    }

    func testApplierKnowsQuotesOfTheFile() {
        let file = "a\n  b  \nc\n"
        XCTAssertTrue(CodeBlockApplier.alreadyContains("  b\nc", in: file))
        XCTAssertTrue(CodeBlockApplier.alreadyContains("\na\n", in: file))
        XCTAssertFalse(CodeBlockApplier.alreadyContains("B", in: file))
        XCTAssertFalse(CodeBlockApplier.alreadyContains("  \n", in: file))
    }

    func testHighlighterPaintsDarkModernColours() {
        let storage = NSTextStorage(string: "// hi\nconst x = \"s\"; f(1)")
        SyntaxHighlighter.highlight(storage, language: .javascript, font: .systemFont(ofSize: 12))
        func color(at i: Int) -> NSColor { storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as! NSColor }
        XCTAssertEqual(color(at: 0), SyntaxHighlighter.comment)
        XCTAssertEqual(color(at: 6), SyntaxHighlighter.keyword)   // const
        XCTAssertEqual(color(at: 16), SyntaxHighlighter.string)   // "s"
        XCTAssertEqual(color(at: 21), SyntaxHighlighter.function) // f
        XCTAssertEqual(color(at: 23), SyntaxHighlighter.number)   // 1
        XCTAssertEqual(SyntaxHighlighter.language(for: "a/b.css"), .css)
        XCTAssertEqual(SyntaxHighlighter.language(for: "x.mjs"), .javascript)
        XCTAssertEqual(SyntaxHighlighter.language(for: "README"), .other)
    }
}

@MainActor
final class XcodeRunnerParseTests: XCTestCase {
    func testParsesDiagnosticsRelativeToRoot() {
        let root = URL(fileURLWithPath: "/Users/me/App")
        let log = """
        CompileSwift normal arm64
        /Users/me/App/App/ContentView.swift:42:9: error: cannot find 'foo' in scope
                foo()
        /Users/me/App/App/ContentView.swift:42:9: error: cannot find 'foo' in scope
        /Users/me/App/App/Model.swift:7:5: warning: variable 'x' was never used
        error: linker command failed with exit code 1
        ** BUILD FAILED **
        """
        let errs = XcodeRunner.parseErrors(log, root: root)
        XCTAssertEqual(errs.count, 3)
        XCTAssertEqual(errs[0].file, "App/ContentView.swift")
        XCTAssertEqual(errs[0].line, 42)
        XCTAssertEqual(errs[0].message, "cannot find 'foo' in scope")
        XCTAssertFalse(errs[0].isWarning)
        XCTAssertEqual(errs[1].file, "")
        XCTAssertEqual(errs[1].message, "linker command failed with exit code 1")
        XCTAssertTrue(errs[2].isWarning)
        XCTAssertEqual(errs[2].file, "App/Model.swift")
    }
}

final class CodeBlockLocatorTests: XCTestCase {
    private let files: [String: String] = [
        "app.js": """
        const timeSignupStart = 19;

        function getSeattleScheduleMode(now) {
          return now.getHours() >= timeSignupStart ? 'lineup' : 'signup';
        }

        function initializeApp() {
          render();
        }
        """,
        "css/style.css": ".tag-new { color: red; }\n",
    ]
    private var paths: [String] { Array(files.keys).sorted() }

    func testFenceCarriesFilePath() {
        let segs = CodeAnswerSegment.parse("```js app.js\nfoo()\n```\n```src/x.py\nprint(1)\n```")
        XCTAssertEqual(segs[0], .code(language: "js", code: "foo()", file: "app.js"))
        XCTAssertEqual(segs[1], .code(language: "py", code: "print(1)", file: "src/x.py"))
    }

    func testPathOnFirstLineOfBlockBecomesTheTag() {
        let segs = CodeAnswerSegment.parse("```json\ndata/open-mics.json\n  {\n    \"id\": \"x\"\n```")
        XCTAssertEqual(segs, [.code(language: "json", code: "  {\n    \"id\": \"x\"", file: "data/open-mics.json")])
        // Real code that happens to have a dot stays put.
        XCTAssertEqual(CodeAnswerSegment.parse("```js\nfoo.bar()\nbaz()\n```"),
                       [.code(language: "js", code: "foo.bar()\nbaz()", file: nil)])
        XCTAssertEqual(CodeAnswerSegment.parse("```\nREADME.md\n```"), [.code(language: "", code: "README.md", file: nil)])
    }

    func testLocatesFindBlockInTaggedFile() {
        let find = "function initializeApp() {\n  render();\n}"
        let loc = CodeBlockLocator.locate(code: "function initializeApp() {\n  boot();\n}", find: find, tagged: "app.js",
                                          focused: "css/style.css", paths: paths) { self.files[$0] }
        XCTAssertEqual(loc, .init(path: "app.js", line: 7, lineCount: 3))
    }

    func testFallsBackToDefinedName() {
        let loc = CodeBlockLocator.locate(code: "function getSeattleScheduleMode(now) {\n  return 'x';\n}", find: nil, tagged: nil,
                                          focused: nil, paths: paths) { self.files[$0] }
        XCTAssertEqual(loc?.path, "app.js")
        XCTAssertEqual(loc?.line, 3)
    }

    func testResolvesBySuffixAndLeaf() {
        XCTAssertEqual(CodeBlockLocator.resolve("style.css", in: paths), "css/style.css")
        XCTAssertEqual(CodeBlockLocator.resolve("./app.js", in: paths), "app.js")
        XCTAssertNil(CodeBlockLocator.resolve("nope.js", in: paths))
    }

    func testIdentifierFindsDefinitionOverUse() {
        let loc = CodeBlockLocator.locate(identifier: "timeSignupStart", focused: nil, paths: paths) { self.files[$0] }
        XCTAssertEqual(loc?.line, 1)
        let fn = CodeBlockLocator.locate(identifier: "initializeApp()", focused: nil, paths: paths) { self.files[$0] }
        XCTAssertEqual(fn?.line, 7)
        XCTAssertNil(CodeBlockLocator.locate(identifier: "nothingHere", focused: nil, paths: paths) { self.files[$0] })
    }
}


final class LineDiffTests: XCTestCase {
    func testIdenticalTextsAreAllSame() {
        let text = "a\nb\nc\n"
        let lines = LineDiff.diff(text, text)
        XCTAssertTrue(lines.allSatisfy { $0.kind == .same })
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testSingleInsertedLine() {
        let lines = LineDiff.diff("a\nb\n", "a\nx\nb\n")
        XCTAssertEqual(lines, [
            .init(kind: .same, text: "a"),
            .init(kind: .added, text: "x"),
            .init(kind: .same, text: "b"),
        ])
    }

    func testChangedLineIsRemovedThenAdded() {
        let lines = LineDiff.diff("a\nb\nc\n", "a\nB\nc\n")
        XCTAssertEqual(lines, [
            .init(kind: .same, text: "a"),
            .init(kind: .removed, text: "b"),
            .init(kind: .added, text: "B"),
            .init(kind: .same, text: "c"),
        ])
    }

    func testTrailingWhitespaceOnlyChangeIsIgnored() {
        let lines = LineDiff.diff("a\nb  \nc\n", "a\nb\t\nc\n")
        XCTAssertTrue(lines.allSatisfy { $0.kind == .same })
    }

    func testSummaryCountsAddedAndRemoved() {
        let lines = LineDiff.diff("a\nb\nc\n", "a\nB\nc\nd\n")
        let summary = LineDiff.summary(lines)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.removed, 1)
    }
}

final class BracketMatcherTests: XCTestCase {
    func testMatchesFromEitherSideOfCaret() {
        let text = "fn(a, [1, 2]) {\n  x\n}" as NSString
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: 3), .init(open: 2, close: 12))   // after (
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: 2), .init(open: 2, close: 12))   // before (
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: 12), .init(open: 6, close: 11))  // after ] wins over before )
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: text.length), .init(open: 14, close: text.length - 1))
    }

    func testIgnoresBracketsInsideStrings() {
        let text = "{ \"a\": \"}\", \"b\": [1] }" as NSString
        XCTAssertEqual(BracketMatcher.pair(in: text, caret: 1), .init(open: 0, close: text.length - 1))
        XCTAssertNil(BracketMatcher.pair(in: text, caret: 10)) // caret next to the quoted }
    }

    func testUnbalancedReturnsNil() {
        XCTAssertNil(BracketMatcher.pair(in: "( a ( b", caret: 1))
        XCTAssertNil(BracketMatcher.pair(in: "a ) b", caret: 3))
        XCTAssertNil(BracketMatcher.pair(in: "plain text", caret: 3))
    }
}
