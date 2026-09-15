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
}
