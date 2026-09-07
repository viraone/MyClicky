import XCTest
@testable import MyClicky

@MainActor
final class TerminalDictationTests: XCTestCase {
    private func text(_ phrase: String, active: Bool = false) -> String? {
        AssistantController.terminalDictation(phrase, terminalActive: active)?.text
    }

    func testShellPhrasings() {
        XCTAssertEqual(text("tell the terminal to run the tests"), "run the tests")
        XCTAssertEqual(text("Clicky, tell the terminal npm test"), "npm test")
        XCTAssertEqual(text("in the terminal, type git status"), "git status")
        XCTAssertEqual(text("in the terminal run swift build"), "swift build")
        XCTAssertEqual(text("type make in the terminal"), "make")
        XCTAssertEqual(text("run swift test in the terminal"), "swift test")
        XCTAssertEqual(text("type in the terminal: ls"), "ls")
        XCTAssertEqual(text("terminal: pwd"), "pwd")
        XCTAssertEqual(text("okay can you tell the shell to git pull"), "git pull")
    }

    func testAgentPhrasingsKeepNaturalLanguage() {
        let d = AssistantController.terminalDictation("tell Claude to fix the failing test and dash dash keep the API", terminalActive: false)
        XCTAssertEqual(d?.text, "fix the failing test and dash dash keep the API")
        XCTAssertEqual(d?.agent, true)
        XCTAssertEqual(text("ask copilot to explain this stack trace"), "explain this stack trace")
        XCTAssertEqual(text("tell the agent add a README"), "add a README")
    }

    func testSpokenSymbolsForShellCommands() {
        XCTAssertEqual(text("tell the terminal npm test dash dash watch"), "npm test --watch")
        XCTAssertEqual(text("tell the terminal ls dash la"), "ls -la")
        XCTAssertEqual(text("tell the terminal run dot slash build dot sh"), "run ./build.sh")
        XCTAssertEqual(text("tell the terminal cd tilde slash projects"), "cd ~/projects")
        XCTAssertEqual(text("tell the terminal git log pipe head"), "git log | head")
    }

    func testAppendOnlyWhileALineIsTyped() {
        XCTAssertNil(text("type dash dash verbose"))
        let d = AssistantController.terminalDictation("add dash dash verbose", terminalActive: true)
        XCTAssertEqual(d?.text, " --verbose")
        XCTAssertEqual(d?.append, true)
    }

    func testNotTerminalSpeech() {
        for phrase in ["tell him I'll be there at seven", "open a conversation with Dino Dad", "send it", "erase that",
                       "what's on my screen", "tell Dino Dad the terminal is broken", "run it"] {
            XCTAssertNil(text(phrase), phrase)
        }
    }

    func testRunIt() {
        for phrase in ["run it", "Run it.", "hit enter", "press enter", "execute", "okay run it now", "go ahead and run it",
                       "hit return", "run that command"] {
            XCTAssertTrue(AssistantController.isRunIt(phrase), phrase)
        }
        for phrase in ["run the tests", "go to bed", "enter the building", "return the book", "send it"] {
            XCTAssertFalse(AssistantController.isRunIt(phrase), phrase)
        }
    }
}
