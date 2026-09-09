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
}
