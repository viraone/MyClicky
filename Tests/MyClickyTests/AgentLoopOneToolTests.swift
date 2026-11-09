import XCTest
@testable import MyClicky

private final class FakeAgentModelClient: AgentModelClient, @unchecked Sendable {
    private let replies: [(content: [[String: Any]], stopReason: String)]
    private var nextReply = 0
    private(set) var sentMessages: [[[String: Any]]] = []

    init(replies: [(content: [[String: Any]], stopReason: String)]) {
        self.replies = replies
    }

    func send(system: String,
              messages: [[String: Any]],
              tools: [[String: Any]]) async throws -> (content: [[String: Any]], stopReason: String) {
        sentMessages.append(messages)
        let reply: (content: [[String: Any]], stopReason: String)
        if nextReply < replies.count {
            reply = replies[nextReply]
        } else {
            reply = (content: [["type": "text", "text": "No more replies"]], stopReason: "end_turn")
        }
        nextReply += 1
        return reply
    }
}

private final class FakeAgentToolRunner: AgentToolRunning, @unchecked Sendable {
    var specs: [[String: Any]] { [] }
    private(set) var calls: [(name: String, input: [String: Any])] = []

    func run(name: String, input: [String: Any]) async -> AgentToolOutcome {
        calls.append((name: name, input: input))
        return AgentToolOutcome(text: "ok", summary: "did it")
    }
}

final class AgentLoopOneToolTests: XCTestCase {
    private var toolUseReply: (content: [[String: Any]], stopReason: String) {
        (
            content: [
                ["type": "tool_use", "id": "t1", "name": "do_it", "input": ["a": 1]],
                ["type": "tool_use", "id": "t2", "name": "do_it", "input": ["b": 2]],
            ],
            stopReason: "tool_use"
        )
    }

    private var finishedReply: (content: [[String: Any]], stopReason: String) {
        (content: [["type": "text", "text": "Finished"]], stopReason: "end_turn")
    }

    @MainActor
    func testOneToolPerStepRunsOnlyTheFirstTool() async throws {
        let client = FakeAgentModelClient(replies: [toolUseReply, finishedReply])
        let tools = FakeAgentToolRunner()
        let loop = AgentLoop(client: client, tools: tools, oneToolPerStep: true) { _ in }

        let answer = try await loop.run(task: "Do the thing", history: [])

        XCTAssertEqual(answer, "Finished")
        XCTAssertEqual(tools.calls.count, 1)
        let firstCall = try XCTUnwrap(tools.calls.first)
        XCTAssertEqual(firstCall.name, "do_it")
        XCTAssertEqual(firstCall.input["a"] as? Int, 1)
        XCTAssertNil(firstCall.input["b"])

        XCTAssertEqual(client.sentMessages.count, 2)
        let secondCallMessages = try XCTUnwrap(client.sentMessages.last)
        XCTAssertEqual(secondCallMessages.last?["role"] as? String, "user")
        let blocks = try XCTUnwrap(secondCallMessages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)

        let firstResult = try XCTUnwrap(blocks.first)
        XCTAssertEqual(firstResult["type"] as? String, "tool_result")
        XCTAssertEqual(firstResult["tool_use_id"] as? String, "t1")
        XCTAssertEqual(firstResult["content"] as? String, "ok")
        XCTAssertEqual(firstResult["is_error"] as? Bool, false)

        let secondResult = blocks[1]
        XCTAssertEqual(secondResult["type"] as? String, "tool_result")
        XCTAssertEqual(secondResult["tool_use_id"] as? String, "t2")
        XCTAssertEqual(secondResult["is_error"] as? Bool, true)
        XCTAssertEqual(secondResult["content"] as? String,
                       "Not run. Only one tool runs per step because the document changes after each one. Read the result above, then call this again if it is still needed.")
    }

    @MainActor
    func testDefaultRunsEveryTool() async throws {
        let client = FakeAgentModelClient(replies: [toolUseReply, finishedReply])
        let tools = FakeAgentToolRunner()
        let loop = AgentLoop(client: client, tools: tools) { _ in }

        let answer = try await loop.run(task: "Do the thing", history: [])

        XCTAssertEqual(answer, "Finished")
        XCTAssertEqual(tools.calls.count, 2)
        let firstCall = try XCTUnwrap(tools.calls.first)
        let secondCall = try XCTUnwrap(tools.calls.dropFirst().first)
        XCTAssertEqual(firstCall.name, "do_it")
        XCTAssertEqual(firstCall.input["a"] as? Int, 1)
        XCTAssertEqual(secondCall.name, "do_it")
        XCTAssertEqual(secondCall.input["b"] as? Int, 2)
    }
}
