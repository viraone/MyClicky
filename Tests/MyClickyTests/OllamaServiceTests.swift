import Foundation
import XCTest
@testable import MyClicky

@MainActor
final class OllamaServiceTests: XCTestCase {
    func testNumberedLinesAlignAndStartAtOne() {
        let text = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let lines = OllamaService.numbered(text).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines[0], " 1 | line1")
        XCTAssertEqual(lines[9], "10 | line10")
    }

    func testLiveLocalCodeQuestion() async throws {
        guard ProcessInfo.processInfo.environment["RUN_OLLAMA_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_OLLAMA_INTEGRATION=1 to use the installed local model.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const answer = 42\n".write(
            to: root.appendingPathComponent("answer.ts"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))
        let service = OllamaService()
        let model = ProcessInfo.processInfo.environment["OLLAMA_TEST_MODEL"] ?? "qwen3-coder:30b"

        let models = try await service.models()
        XCTAssertTrue(models.contains(model))
        let answer = try await service.askAboutCode(
            question: "Reply with exactly LOCAL_OK and nothing else.",
            project: project,
            focusedFile: "answer.ts",
            changedFiles: [],
            history: [],
            model: model
        )
        XCTAssertTrue(answer.contains("LOCAL_OK"))
    }

    func testLocalMessagesRestateTheEditFormat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-messages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const answer = 42\n".write(
            to: root.appendingPathComponent("answer.ts"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let messages = OllamaService.messages(question: "Make it 43", project: project, focusedFile: "answer.ts",
                                              changedFiles: [], history: [(question: "Q1", answer: "A1")])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        let system = try XCTUnwrap(messages[0]["content"])
        XCTAssertTrue(system.contains(AnthropicService.codeSystemPrompt), "same prompt Claude gets")
        XCTAssertTrue(system.contains(OllamaService.editFormatReminder), "plus the local-model reminder")
        XCTAssertTrue(system.contains("===== FILE: answer.ts"), "and the project itself")
        let last = try XCTUnwrap(messages[3]["content"])
        XCTAssertTrue(last.contains("Make it 43"))
        XCTAssertTrue(last.contains("1 | export const answer = 42"), "focused file rides along with line numbers")
        XCTAssertTrue(last.hasSuffix(OllamaService.questionReminder), "reminder is the last thing the model reads")
    }

    func testContextWindowSnapsToBucketsAndRespectsTheModelLimit() {
        func messages(characters: Int) -> [[String: String]] {
            [["role": "user", "content": String(repeating: "x", count: characters)]]
        }
        XCTAssertEqual(OllamaService.estimatedTokens(of: messages(characters: 3_500)), 1_000)
        // A tiny prompt gets the smallest bucket, however roomy the model.
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: 7_000), limit: 262_144), 8_192)
        // ~20K tokens of prompt plus answer headroom needs the 32K bucket.
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: 70_000), limit: 262_144), 32_768)
        // Just past a bucket edge steps up rather than squeezing.
        let edge = (32_768 - OllamaService.answerHeadroom) * 35 / 10
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: edge), limit: 262_144), 32_768)
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: edge + 350), limit: 262_144), 65_536)
        // A model with a smaller window caps the bucket at its own limit.
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: 70_000), limit: 30_000), 30_000)
        // Unknown limit: buckets alone.
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: 7_000), limit: nil), 8_192)
        // Too big for the model: nil, so the caller explains instead of letting Ollama truncate the prompt.
        XCTAssertNil(OllamaService.contextWindow(for: messages(characters: 200_000), limit: 32_768))
        XCTAssertTrue(OllamaService.OllamaError.tooLarge(tokens: 57_000, limit: 32_768).localizedDescription.contains("57K tokens"))
    }
}
