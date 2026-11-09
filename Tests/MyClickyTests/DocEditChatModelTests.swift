import XCTest
@testable import MyClicky

/// Plays back a fixed list of model replies, in order, like DeepSeek would send them.
private final class ScriptedClient: AgentModelClient {
    private var replies: [(content: [[String: Any]], stopReason: String)]
    private(set) var systems: [String] = []

    init(_ replies: [(content: [[String: Any]], stopReason: String)]) {
        self.replies = replies
    }

    func send(system: String,
              messages: [[String: Any]],
              tools: [[String: Any]]) async throws -> (content: [[String: Any]], stopReason: String) {
        systems.append(system)
        return replies.removeFirst()
    }
}

private final class RenderCounter: @unchecked Sendable {
    var calls = 0
}

/// The whole chain with a scripted stand-in for DeepSeek: chat model, agent loop, the real tools, the real project files.
@MainActor
final class DocEditChatModelTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("docchat-\(UUID().uuidString)", isDirectory: true)
        let audio = folder.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let script: [String: Any] = [
            "title": "Test Film",
            "scenes": [
                ["id": "title", "kind": "title", "narration": "Opening."],
                ["id": "code1", "kind": "code", "heading": "Why async", "narration": "Instagram. Copy the link and paste it into Safari."],
                ["id": "code2", "kind": "code", "heading": "Why await", "narration": "Second code."],
                ["id": "credits", "kind": "credits", "narration": "The end."],
            ],
        ]
        try JSONSerialization.data(withJSONObject: script).write(to: folder.appendingPathComponent("script.json"))
        let timeline: [String: Any] = ["scenes": [
            ["id": "title", "start": 0.0, "end": 8.0], ["id": "code1", "start": 8.0, "end": 20.0],
            ["id": "code2", "start": 20.0, "end": 35.0], ["id": "credits", "start": 35.0, "end": 40.0],
        ]]
        try JSONSerialization.data(withJSONObject: timeline).write(to: folder.appendingPathComponent("timeline.json"))
        for id in ["title", "code1", "code2", "credits"] {
            try Data([1, 2, 3]).write(to: audio.appendingPathComponent("\(id).wav"))
        }
        try Data("{\"voice\":\"am_michael\"}".utf8).write(to: audio.appendingPathComponent("voice.json"))
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("documentary.mp4"))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func narration(of id: String) throws -> String? {
        let scenes = try DocEditProject(folder: folder).scenes()
        return scenes.first { $0.id == id }?.narration
    }

    private func waitUntilIdle(_ model: DocEditChatModel) async throws {
        for _ in 0..<250 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The chat never finished.")
    }

    func testChatChangesTheNarrationThenRendersOnceAndCanRestore() async throws {
        let newText = "You can also open it any other mobile browser."
        let client = ScriptedClient([
            ([["type": "text", "text": "I'll change that sentence."],
              ["type": "tool_use", "id": "t1", "name": "set_narration", "input": ["scene_id": "code1", "text": newText]],
              // The same edit twice in one step: the second one must not run.
              ["type": "tool_use", "id": "t2", "name": "set_narration", "input": ["scene_id": "code1", "text": "Should not be applied."]]], "tool_use"),
            ([["type": "tool_use", "id": "t3", "name": "render", "input": [String: Any]()]], "tool_use"),
            ([["type": "text", "text": "Done. The film is re-rendered."]], "end_turn"),
        ])
        let renders = RenderCounter()
        var filmChanged = 0
        let model = DocEditChatModel(
            project: DocEditProject(folder: folder),
            makeClient: { client },
            renderer: { _ in renders.calls += 1; return "Rendered." },
            onFilmChanged: { filmChanged += 1 }
        )

        model.send("Change the narration at 0:10 to: \(newText)")
        try await waitUntilIdle(model)

        XCTAssertNil(model.errorText)
        XCTAssertEqual(try narration(of: "code1"), newText)
        XCTAssertEqual(renders.calls, 1)
        XCTAssertEqual(model.messages.last?.text, "Done. The film is re-rendered.")
        XCTAssertEqual(model.messages.last?.steps.count, 2)   // the refused duplicate edit shows no step
        // The model was told what the film says right now, with times.
        XCTAssertTrue(client.systems[0].contains("id=code1 kind=code heading=\"Why async\" 0:08.0-0:20.0"))
        XCTAssertTrue(client.systems[0].contains("Instagram. Copy the link and paste it into Safari."))
        // The wav of the changed scene was removed so only it is re-recorded; the others stay.
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio/code1.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio/code2.wav").path))
        XCTAssertTrue(model.canRestore)

        model.restoreOriginal()
        XCTAssertEqual(try narration(of: "code1"), "Instagram. Copy the link and paste it into Safari.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio/code1.wav").path))
        XCTAssertFalse(model.canRestore)
        XCTAssertEqual(filmChanged, 1)
    }

    func testAFailingModelShowsAnErrorAndKeepsTheFilm() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "No DeepSeek API key found." } }
        final class FailingClient: AgentModelClient {
            func send(system: String, messages: [[String: Any]], tools: [[String: Any]]) async throws -> (content: [[String: Any]], stopReason: String) {
                throw Boom()
            }
        }
        let model = DocEditChatModel(project: DocEditProject(folder: folder), makeClient: { FailingClient() },
                                     renderer: { _ in "Rendered." }, onFilmChanged: {})
        model.send("Make the intro shorter")
        try await waitUntilIdle(model)
        XCTAssertEqual(model.errorText, "No DeepSeek API key found.")
        XCTAssertEqual(model.messages.count, 1)   // the empty assistant bubble was dropped
        XCTAssertEqual(try narration(of: "code1"), "Instagram. Copy the link and paste it into Safari.")
    }
}
