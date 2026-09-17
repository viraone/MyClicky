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
        XCTAssertTrue(system.contains("  answer.ts"), "the project tree remains available")
        XCTAssertFalse(system.contains("===== FILE: answer.ts"), "the focused file is not sent twice")
        XCTAssertTrue(system.contains("1 | export const answer = 42"),
                      "focused file rides in the system prefix, with line numbers, where Ollama can cache it")
        XCTAssertTrue(system.hasSuffix(OllamaService.brevityRule),
                      "brevity rule comes after the file so a small model still has it in view")
        let last = try XCTUnwrap(messages[3]["content"])
        XCTAssertTrue(last.hasPrefix("Make it 43"), "the question is all that changes between turns")
        XCTAssertTrue(last.hasSuffix(OllamaService.questionReminder), "reminder is the last thing the model reads")
    }

    func testSystemPrefixIsIdenticalAcrossTurnsSoOllamaCanCacheIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const answer = 42\n".write(
            to: root.appendingPathComponent("answer.ts"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let first = OllamaService.messages(question: "What is this?", project: project, focusedFile: "answer.ts",
                                           changedFiles: [], history: [])
        let second = OllamaService.messages(question: "Make it 43", project: project, focusedFile: "answer.ts",
                                            changedFiles: [], history: [(question: "What is this?", answer: "A constant.")])
        XCTAssertEqual(first[0], second[0], "same system message → Ollama reuses the cached prefix")
        XCTAssertEqual(second.count, 4)
        XCTAssertLessThan(second[3]["content"]?.count ?? .max, 400, "the new turn is tiny")
    }

    func testSlicePutsReadmeManifestsAndEntryPointsFirst() {
        func file(_ path: String) -> CodeProject.File { .init(path: path, text: "x") }
        let files = [file("zeta.ts"), file("src/util/helper.ts"), file("src/index.ts"),
                     file("docs/GUIDE.md"), file("package.json"), file("README.md"), file("alpha.ts")]
        let ordered = OllamaService.slicePriority(files).map(\.path)
        XCTAssertEqual(ordered, ["README.md", "package.json", "src/index.ts", "docs/GUIDE.md",
                                 "zeta.ts", "alpha.ts", "src/util/helper.ts"])
    }

    func testTimingLineReportsCacheHits() {
        let hit = OllamaService.timingLine(["prompt_eval_count": 17_412, "prompt_eval_duration": 120_000_000,
                                            "eval_count": 312, "eval_duration": 4_300_000_000])
        XCTAssertEqual(hit, "read 17K tokens in 0.1 s (cached) · wrote 312 tokens in 4.3 s")
        let miss = OllamaService.timingLine(["prompt_eval_count": 17_412, "prompt_eval_duration": 30_000_000_000,
                                             "eval_count": 1_200, "eval_duration": 8_000_000_000])
        XCTAssertEqual(miss, "read 17K tokens in 30.0 s · wrote 1K tokens in 8.0 s")
        XCTAssertNil(OllamaService.timingLine(["message": ["content": "hi"]]))
    }

    func testFocusedFileOmitsLargeUnrelatedFilesFromLocalPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-focused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "const focused = true\n".write(
            to: root.appendingPathComponent("focused.ts"), atomically: true, encoding: .utf8)
        try String(repeating: "unrelated-data\n", count: 10_000).write(
            to: root.appendingPathComponent("large.json"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let messages = OllamaService.messages(question: "Explain this file", project: project,
                                              focusedFile: "focused.ts", changedFiles: [], history: [])
        let combined = messages.compactMap { $0["content"] }.joined(separator: "\n")
        XCTAssertTrue(combined.contains("1 | const focused = true"))
        XCTAssertFalse(combined.contains("unrelated-data"))
        XCTAssertLessThan(OllamaService.estimatedTokens(of: messages), 10_000)
    }

    func testLargeFocusedFileIsExcerptedWithOriginalLineNumbers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-large-focused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (1...3_000).map { "record \($0): \(String(repeating: "x", count: 40))" }
            .joined(separator: "\n")
        try text.write(to: root.appendingPathComponent("large.json"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let messages = OllamaService.messages(question: "Summarize it", project: project,
                                              focusedFile: "large.json", changedFiles: [], history: [])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("1 | record 1:"))
        XCTAssertTrue(system.contains("3000 | record 3000:"))
        XCTAssertTrue(system.contains("lines omitted to keep local Qwen responsive"))
        XCTAssertLessThan(system.count, OllamaService.maxLocalFocusedFileCharacters + 6_000)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(OllamaService.contextWindow(for: messages, limit: 262_144)),
            32_768
        )
    }

    func testFocusedChangedFileIsIncludedOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-current-focused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "old".write(to: root.appendingPathComponent("answer.ts"), atomically: true, encoding: .utf8)
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let messages = OllamaService.messages(question: "Review it", project: project,
                                              focusedFile: "answer.ts",
                                              changedFiles: [(path: "answer.ts", text: "unique-current-text")],
                                              history: [])
        let combined = messages.compactMap { $0["content"] }.joined(separator: "\n")
        XCTAssertEqual(combined.components(separatedBy: "unique-current-text").count - 1, 1)
    }

    func testNoFocusedFileUsesBoundedLocalProjectSlice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeky-ollama-slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try String(repeating: "\(index)", count: 40_000).write(
                to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8)
        }
        let project = try XCTUnwrap(CodeProjectBundler.bundle(urls: [root]))

        let context = OllamaService.localProjectContext(project, focusedFile: nil)
        XCTAssertLessThan(context.count, OllamaService.maxLocalProjectCharacters + 1_000)
        XCTAssertTrue(context.contains("files omitted from the local slice"))
    }

    func testLocalAskMessagesIncludeContextAndHistory() throws {
        let messages = OllamaService.askMessages(
            question: "What does this mean?",
            context: "The focused editor contains: let answer = 42",
            history: [(question: "Earlier question", answer: "Earlier answer")]
        )

        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertTrue(try XCTUnwrap(messages[0]["content"]).contains("cannot see the user's screen"))
        XCTAssertEqual(messages[1]["content"], "Earlier question")
        XCTAssertEqual(messages[2]["content"], "Earlier answer")
        let current = try XCTUnwrap(messages[3]["content"])
        XCTAssertTrue(current.contains("let answer = 42"))
        XCTAssertTrue(current.hasSuffix("What does this mean?"))
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
        // A long JSON answer reserves its own room: 8K of prompt plus 9K of script needs the 32K bucket.
        XCTAssertEqual(OllamaService.contextWindow(for: messages(characters: 28_000), limit: 262_144, headroom: 9_000), 32_768)
        XCTAssertTrue(OllamaService.OllamaError.tooLarge(tokens: 57_000, limit: 32_768).localizedDescription.contains("57K tokens"))
    }

    func testServerIsStartedWithAOneModelLimitUnlessTheUserSaidOtherwise() {
        let env = OllamaService.serverEnvironment(base: ["PATH": "/opt/homebrew/bin"])
        XCTAssertEqual(env["OLLAMA_MAX_LOADED_MODELS"], "1")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin", "the rest of the environment passes through")
        let explicit = OllamaService.serverEnvironment(base: ["OLLAMA_MAX_LOADED_MODELS": "2"])
        XCTAssertEqual(explicit["OLLAMA_MAX_LOADED_MODELS"], "2", "a deliberate setting wins")
    }
}
