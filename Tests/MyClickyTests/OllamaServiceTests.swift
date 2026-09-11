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
}
