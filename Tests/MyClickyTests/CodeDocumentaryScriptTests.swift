import XCTest
@testable import MyClicky

@MainActor
final class CodeDocumentaryScriptTests: XCTestCase {
    private func scene(_ kind: String, id: String? = nil, lines: [Int]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var s: [String: Any] = ["kind": kind, "narration": "Words."]
        if let id { s["id"] = id }
        if let lines { s["lines"] = lines }
        extra.forEach { s[$0.key] = $0.value }
        return s
    }

    func testClampsLineRangesAndFillsHeading() throws {
        var json: [String: Any] = ["title": "T", "scenes": [scene("code", id: "a", lines: [0, 500])]]
        try CodeDocumentaryModel.validate(&json, lineCount: 40)
        let scenes = json["scenes"] as! [[String: Any]]
        XCTAssertEqual(scenes[0]["lines"] as! [Int], [1, 31])   // capped at 30 lines
        XCTAssertEqual(scenes[0]["heading"] as! String, "Lines 1–31")
    }

    func testDeduplicatesAndSanitisesIDs() throws {
        var json: [String: Any] = ["scenes": [
            scene("code", id: "Hero Function!", lines: [1, 3]),
            scene("code", id: "hero-function", lines: [4, 6]),
            scene("code", lines: [7, 9]),
        ]]
        try CodeDocumentaryModel.validate(&json, lineCount: 20)
        let ids = (json["scenes"] as! [[String: Any]]).map { $0["id"] as! String }
        XCTAssertEqual(ids, ["hero_function_", "hero_function", "scene_3"])
        XCTAssertEqual(json["title"] as? String, "THE CODE")
    }

    func testDropsBrokenScenesButKeepsFilm() throws {
        var json: [String: Any] = ["scenes": [
            scene("title", id: "open"),
            scene("code", id: "bad", lines: [5]),                       // malformed range
            scene("example", id: "ex", extra: ["steps": [["a"]]]),      // pair missing value
            scene("list", id: "l", extra: ["items": [String]()]),        // empty
            scene("mystery", id: "m"),                                  // unknown kind
            scene("code", id: "ok", lines: [2, 4]),
            scene("credits", id: "end"),
        ]]
        try CodeDocumentaryModel.validate(&json, lineCount: 10)
        let ids = (json["scenes"] as! [[String: Any]]).map { $0["id"] as! String }
        XCTAssertEqual(ids, ["open", "ok", "end"])
    }

    func testThrowsWithoutCodeScenes() {
        var json: [String: Any] = ["scenes": [scene("title", id: "open")]]
        XCTAssertThrowsError(try CodeDocumentaryModel.validate(&json, lineCount: 10))
        var empty: [String: Any] = ["scenes": []]
        XCTAssertThrowsError(try CodeDocumentaryModel.validate(&empty, lineCount: 10))
    }

    func testTypedPathRejectsFoldersAndAcceptsFiles() throws {
        let model = CodeDocumentaryModel()
        XCTAssertFalse(model.setSource(path: NSTemporaryDirectory()))
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doc-\(UUID().uuidString).ts")
        try "const a = 1;\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(model.setSource(path: "  \(file.path)  "))
        XCTAssertEqual(model.sourceFile, file)
        XCTAssertEqual(model.phase, .idle)
    }

    func testWriteScriptFeedsNumberedFileToRequesterAndValidates() async throws {
        let source = URL(fileURLWithPath: "/tmp/hello.swift")
        var seen: (system: String, user: String)?
        let script = try await CodeDocumentaryModel.writeScript(for: "let a = 1\nlet b = 2\n", at: source) { system, user in
            seen = (system, user)
            return ["title": "", "scenes": [
                ["id": "open", "kind": "title", "narration": "Hi."],
                ["id": "c", "kind": "code", "lines": [1, 99], "narration": "Two lets."],
            ]]
        }
        XCTAssertEqual(seen?.system, CodeDocumentaryModel.scriptSystemPrompt)
        XCTAssertTrue(seen?.user.contains("   1| let a = 1") ?? false, "lines are numbered for the model")
        XCTAssertTrue(seen?.user.contains("Lines: 3") ?? false)
        XCTAssertEqual(script["source"] as? String, source.path)
        XCTAssertEqual(script["title"] as? String, "THE CODE", "validate() repairs the local model's output")
        let code = (script["scenes"] as! [[String: Any]])[1]
        XCTAssertEqual(code["lines"] as! [Int], [1, 3])
    }

    func testScriptEngineTagRoundTripsProviderAndModel() {
        let model = CodeDocumentaryModel()
        model.scriptEngine = "ollama:qwen3-coder:30b"
        XCTAssertEqual(model.scriptProvider, .ollama)
        XCTAssertEqual(model.ollamaModel, "qwen3-coder:30b")
        XCTAssertEqual(model.scriptEngine, "ollama:qwen3-coder:30b")
        XCTAssertEqual(model.scriptWriterLabel, "Qwen3-Coder 30B")

        model.scriptEngine = "claude"
        XCTAssertEqual(model.scriptProvider, .claude)
        XCTAssertEqual(model.ollamaModel, "qwen3-coder:30b", "last local choice is remembered")
        XCTAssertEqual(model.scriptWriterLabel, "Claude")

        model.scriptEngine = "garbage"
        XCTAssertEqual(model.scriptProvider, .claude, "unknown tags are ignored")
    }

    func testOllamaChoicesKeepDefaultFirstAndFoldLatestTags() {
        let model = CodeDocumentaryModel()
        model.scriptEngine = "ollama:\(CodeDocumentaryModel.defaultOllamaModel)"
        model.ollamaModels = ["qwen3-coder-next:latest", "qwen3-coder:30b", "llama3.1:8b"]
        XCTAssertEqual(model.ollamaChoices, ["qwen3-coder-next", "qwen3-coder:30b", "llama3.1:8b"])

        model.ollamaModel = "llama3.1:8b"
        XCTAssertEqual(model.ollamaChoices.first, "llama3.1:8b", "the chosen model always appears")
        XCTAssertTrue(model.ollamaChoices.contains("qwen3-coder-next"))
    }
}
