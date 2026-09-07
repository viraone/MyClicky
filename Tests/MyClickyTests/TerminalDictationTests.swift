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

@MainActor
final class TerminalTargetingTests: XCTestCase {
    func testAgentDetectedFromProcessList() {
        XCTAssertEqual(TerminalActions.agentName(in: ["login -pf viradeth", "-zsh"]), nil)
        XCTAssertEqual(TerminalActions.agentName(in: ["-zsh", "node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "Claude Code")
        XCTAssertEqual(TerminalActions.agentName(in: ["copilot --model gpt-5"]), "Copilot CLI")
        XCTAssertEqual(TerminalActions.agentName(in: ["/usr/local/bin/codex"]), "Codex")
        // A plain argument mentioning an agent isn't the agent.
        XCTAssertNil(TerminalActions.agentName(in: ["vim notes-about-claude.md"]))
    }

    func testSpokenAgentNormalises() {
        XCTAssertEqual(TerminalActions.agentName(spoken: "Claude Code"), "Claude Code")
        XCTAssertEqual(TerminalActions.agentName(spoken: "claude"), "Claude Code")
        XCTAssertEqual(TerminalActions.agentName(spoken: "Copilot"), "Copilot CLI")
        XCTAssertNil(TerminalActions.agentName(spoken: "the agent"))
    }

    func testScreenHintExtraction() {
        XCTAssertEqual(AssistantController.extractScreenHint("run the tests on the other screen").1, .other)
        XCTAssertEqual(AssistantController.extractScreenHint("run the tests on the other screen").0, "run the tests")
        XCTAssertEqual(AssistantController.extractScreenHint("git status on screen 2").1, .index(2))
        XCTAssertEqual(AssistantController.extractScreenHint("git status on the second monitor").1, .index(2))
        XCTAssertEqual(AssistantController.extractScreenHint("ls on the left screen").1, .left)
        XCTAssertNil(AssistantController.extractScreenHint("open the screen saver settings").1)
    }

    func testDictationCarriesAgentAndScreen() {
        let d = AssistantController.terminalDictation("tell Claude to fix the failing test on the other screen", terminalActive: false)
        XCTAssertEqual(d?.text, "fix the failing test")
        XCTAssertEqual(d?.agent, true)
        XCTAssertEqual(d?.agentName, "Claude Code")
        XCTAssertEqual(d?.screen, .other)

        let g = AssistantController.terminalDictation("ask the agent to explain this file", terminalActive: false)
        XCTAssertEqual(g?.agent, true)
        XCTAssertNil(g?.agentName)
        XCTAssertNil(g?.screen)

        let t = AssistantController.terminalDictation("in the terminal on screen 2 run npm test", terminalActive: false)
        XCTAssertEqual(t?.text, "npm test")
        XCTAssertEqual(t?.screen, .index(2))
    }
}

@MainActor
final class DirectAddressTests: XCTestCase {
    func testAddressingTheAgentByName() {
        let d = AssistantController.terminalDictation("Claude, what does this function do?", terminalActive: false)
        XCTAssertEqual(d?.agent, true)
        XCTAssertEqual(d?.agentName, "Claude Code")
        XCTAssertEqual(d?.text, "what does this function do?")

        let c = AssistantController.terminalDictation("hey copilot explain the failing test", terminalActive: false)
        XCTAssertEqual(c?.agentName, "Copilot CLI")
        XCTAssertEqual(c?.text, "explain the failing test")
    }

    func testRecognizerMishearings() {
        XCTAssertEqual(AssistantController.terminalDictation("cloud what does this do", terminalActive: false)?.agentName, "Claude Code")
        XCTAssertEqual(AssistantController.terminalDictation("tell co-pilot to run the tests", terminalActive: false)?.agentName, "Copilot CLI")
        XCTAssertEqual(TerminalActions.agentName(spoken: "Co Pilot"), "Copilot CLI")
    }

    func testOrdinaryQuestionsAreNotAgentCommands() {
        XCTAssertNil(AssistantController.terminalDictation("what does this function do?", terminalActive: false))
        XCTAssertNil(AssistantController.terminalDictation("the agent is slow today", terminalActive: false))
        XCTAssertNil(AssistantController.terminalDictation("open the cursor settings", terminalActive: false))
    }
}
