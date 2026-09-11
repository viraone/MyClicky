import XCTest
@testable import MyClicky

@MainActor
final class AssistantStateTests: XCTestCase {
    func testChangingTheLocalModelReportsTheOneLeftBehind() {
        let saved = UserDefaults.standard.string(forKey: AssistantState.codeOllamaModelKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AssistantState.codeOllamaModelKey) }
            else { UserDefaults.standard.removeObject(forKey: AssistantState.codeOllamaModelKey) }
        }
        let state = AssistantState()
        state.codeOllamaModel = "qwen3-coder:30b"   // known starting point, before we listen
        var changes: [(from: String, to: String)] = []
        state.onCodeModelChanged = { changes.append((from: $0, to: $1)) }

        state.codeOllamaModel = "qwen3-coder:30b"   // same again: nothing to let go of
        state.codeOllamaModel = "gpt-oss:20b"
        state.codeOllamaModel = "llama3.3:latest"

        XCTAssertEqual(changes.map(\.from), ["qwen3-coder:30b", "gpt-oss:20b"])
        XCTAssertEqual(changes.map(\.to), ["gpt-oss:20b", "llama3.3:latest"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: AssistantState.codeOllamaModelKey), "llama3.3:latest",
                       "the choice still persists")
    }
}
