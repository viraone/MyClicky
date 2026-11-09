import Foundation
import XCTest
@testable import MyClicky

/// Counts renderer calls and can fail on demand. The renderer may run off the
/// main thread, so the counter is marked sendable.
private final class RenderCounter: @unchecked Sendable {
    var calls = 0
    var shouldThrow = false
}

private struct RenderFailure: LocalizedError {
    var errorDescription: String? { "The encoder exploded." }
}

final class DocEditToolRunnerTests: XCTestCase {
    private var folder: URL!
    private var project: DocEditProject!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DocEditToolRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = root
        try writeFixture()
        project = DocEditProject(folder: root)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        project = nil
        try super.tearDownWithError()
    }

    // MARK: - Specs

    func testSpecsHaveFiveToolsInOrderWithSchemas() {
        let runner = makeRunner(project: project, counter: RenderCounter())

        XCTAssertEqual(runner.specs.compactMap { $0["name"] as? String },
                       ["get_script", "set_narration", "set_heading", "delete_scene", "render"])

        for spec in runner.specs {
            let schema = spec["input_schema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object")
            XCTAssertNotNil(schema?["properties"] as? [String: Any])
            XCTAssertNotNil(schema?["required"] as? [String])
        }

        let narration = runner.specs.first { $0["name"] as? String == "set_narration" }
        let narrationSchema = narration?["input_schema"] as? [String: Any]
        XCTAssertEqual(narrationSchema?["required"] as? [String], ["scene_id", "text"])

        let render = runner.specs.first { $0["name"] as? String == "render" }
        let renderSchema = render?["input_schema"] as? [String: Any]
        XCTAssertTrue((renderSchema?["required"] as? [String])?.isEmpty == true)
    }

    // MARK: - Reading the script

    func testGetScriptReturnsTheProjectDescription() async {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "get_script", input: [:])

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.summary, "Read the script")
        XCTAssertTrue(outcome.text.contains("id=code1"))
    }

    // MARK: - Narration

    func testSetNarrationUpdatesTheScriptAndReportsPendingWork() async throws {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "set_narration",
                                       input: ["scene_id": "code1",
                                               "text": "First code, explained."])

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.summary, "Changed the narration of code1")
        XCTAssertTrue(outcome.text.contains("Narration of \"code1\" is now: \"First code, explained.\""))
        XCTAssertTrue(outcome.text.contains("Edited but not rendered yet"))
        XCTAssertTrue(outcome.text.contains("Call render when all edits are done."))

        let script = try readScript()
        XCTAssertEqual(scene("code1", in: script)?["narration"] as? String, "First code, explained.")
    }

    func testSetNarrationWithoutTextIsRejectedAndChangesNothing() async throws {
        let before = try Data(contentsOf: scriptURL)
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "set_narration", input: ["scene_id": "code1"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "set_narration needs scene_id and text.")
        XCTAssertEqual(outcome.summary, "Bad request")
        XCTAssertEqual(try Data(contentsOf: scriptURL), before)
    }

    func testSetNarrationOnAnUnknownSceneReportsTheError() async {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "set_narration",
                                       input: ["scene_id": "nope", "text": "Hello."])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.summary, "Could not change the narration")
        XCTAssertTrue(outcome.text.contains("Unknown scene id"))
    }

    // MARK: - Headings

    func testSetHeadingUpdatesTheScript() async throws {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "set_heading",
                                       input: ["scene_id": "code1", "text": "Why concurrency"])

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.summary, "Changed the heading of code1")
        XCTAssertTrue(outcome.text.contains("Why concurrency"))
        XCTAssertTrue(outcome.text.contains("Edited but not rendered yet"))

        let script = try readScript()
        XCTAssertEqual(scene("code1", in: script)?["heading"] as? String, "Why concurrency")
    }

    // MARK: - Deleting scenes

    func testDeleteSceneRemovesItAndEndsTheAnswerWithTheNewScript() async throws {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "delete_scene", input: ["scene_id": "code2"])

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.summary, "Deleted scene code2")
        XCTAssertTrue(outcome.text.hasPrefix("Deleted scene \"code2\"."))
        XCTAssertTrue(outcome.text.contains("Call render when all edits are done."))
        XCTAssertTrue(outcome.text.contains("id=code1"))
        XCTAssertTrue(outcome.text.contains("id=credits"))

        let script = try readScript()
        XCTAssertNil(scene("code2", in: script))
        XCTAssertEqual((script["scenes"] as? [[String: Any]])?.count, 3)
    }

    func testDeleteSceneRefusesTheCreditsScene() async throws {
        let runner = makeRunner(project: project, counter: RenderCounter())
        let before = try readScript()

        let outcome = await runner.run(name: "delete_scene", input: ["scene_id": "credits"])

        XCTAssertTrue(outcome.isError)
        XCTAssertFalse(outcome.text.isEmpty)
        XCTAssertEqual(outcome.summary, "Could not delete the scene")

        let after = try readScript()
        XCTAssertNotNil(scene("credits", in: after))
        XCTAssertEqual((after["scenes"] as? [[String: Any]])?.count,
                       (before["scenes"] as? [[String: Any]])?.count)
    }

    // MARK: - Rendering

    func testRenderWithoutChangesIsRefusedWithoutCallingTheRenderer() async {
        let counter = RenderCounter()
        let runner = makeRunner(project: project, counter: counter)

        let outcome = await runner.run(name: "render", input: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Nothing to render: no scene has changed since the last render.")
        XCTAssertEqual(outcome.summary, "Nothing to render")
        XCTAssertEqual(counter.calls, 0)
    }

    func testRenderAfterAnEditCallsTheRendererOnceThenStops() async throws {
        let counter = RenderCounter()
        let runner = makeRunner(project: project, counter: counter)
        _ = await runner.run(name: "set_narration",
                             input: ["scene_id": "code1", "text": "First code, revised."])

        let outcome = await runner.run(name: "render", input: [:])

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.summary, "Re-rendered the film")
        XCTAssertEqual(outcome.text, "Rendered the film.")
        XCTAssertEqual(counter.calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioFile("code1.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile("title.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile("code2.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile("credits.wav").path))

        let again = await runner.run(name: "render", input: [:])

        XCTAssertTrue(again.isError)
        XCTAssertEqual(again.text, "Nothing to render: no scene has changed since the last render.")
        XCTAssertEqual(again.summary, "Nothing to render")
        XCTAssertEqual(counter.calls, 1)
    }

    func testRendererFailureKeepsTheChangeDirtyForARetry() async {
        let counter = RenderCounter()
        counter.shouldThrow = true
        let runner = makeRunner(project: project, counter: counter)
        _ = await runner.run(name: "set_narration",
                             input: ["scene_id": "code2", "text": "Second code, revised."])

        let failed = await runner.run(name: "render", input: [:])

        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.summary, "Rendering failed")
        XCTAssertTrue(failed.text.hasPrefix("Rendering failed: "))
        XCTAssertTrue(failed.text.contains("The encoder exploded."))
        XCTAssertEqual(counter.calls, 1)

        counter.shouldThrow = false
        let retried = await runner.run(name: "render", input: [:])

        XCTAssertFalse(retried.isError)
        XCTAssertEqual(retried.summary, "Re-rendered the film")
        XCTAssertEqual(retried.text, "Rendered the film.")
        XCTAssertEqual(counter.calls, 2)
    }

    // MARK: - Unknown tools

    func testUnknownToolIsReported() async {
        let runner = makeRunner(project: project, counter: RenderCounter())

        let outcome = await runner.run(name: "rewind", input: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Unknown tool: rewind")
        XCTAssertEqual(outcome.summary, "Unknown tool")
    }

    // MARK: - Fixture

    private func writeFixture() throws {
        let scenes: [[String: Any]] = [
            ["id": "title", "kind": "title", "narration": "Opening."],
            ["id": "code1", "kind": "code", "heading": "Why async", "narration": "First code."],
            ["id": "code2", "kind": "code", "heading": "Why await", "narration": "Second code."],
            ["id": "credits", "kind": "credits", "narration": "The end."],
        ]
        try writeJSON(["title": "Test Film", "scenes": scenes],
                      to: folder.appendingPathComponent("script.json"))

        let timeline: [[String: Any]] = [
            ["id": "title", "start": 0.0, "end": 8.0],
            ["id": "code1", "start": 8.0, "end": 20.0],
            ["id": "code2", "start": 20.0, "end": 35.0],
            ["id": "credits", "start": 35.0, "end": 40.0],
        ]
        try writeJSON(["scenes": timeline],
                      to: folder.appendingPathComponent("timeline.json"))

        let audio = folder.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for id in ["title", "code1", "code2", "credits"] {
            try Data("wav".utf8).write(to: audio.appendingPathComponent("\(id).wav"))
        }
        try writeJSON(["engine": "kokoro", "voice": "af_heart", "speed": 0.95],
                      to: audio.appendingPathComponent("voice.json"))
        try Data("film".utf8).write(to: folder.appendingPathComponent("documentary.mp4"))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private var scriptURL: URL { folder.appendingPathComponent("script.json") }

    private func readScript() throws -> [String: Any] {
        let data = try Data(contentsOf: scriptURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scene(_ id: String, in script: [String: Any]) -> [String: Any]? {
        let scenes = script["scenes"] as? [[String: Any]] ?? []
        return scenes.first { $0["id"] as? String == id }
    }

    private func audioFile(_ name: String) -> URL {
        folder.appendingPathComponent("audio").appendingPathComponent(name)
    }

    private func makeRunner(project: DocEditProject,
                            counter: RenderCounter,
                            result: String = "Rendered the film.") -> DocEditToolRunner {
        let renderer: @Sendable (DocEditProject) async throws -> String = { _ in
            counter.calls += 1
            if counter.shouldThrow { throw RenderFailure() }
            return result
        }
        return DocEditToolRunner(project: project, renderer: renderer)
    }
}
