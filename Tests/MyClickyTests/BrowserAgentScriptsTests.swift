import XCTest
@testable import MyClicky

final class BrowserAgentScriptsTests: XCTestCase {
    private var sampleScripts: [(name: String, source: String)] {
        [
            ("snapshot", BrowserAgentScripts.snapshot()),
            ("describe", BrowserAgentScripts.describe(id: 3)),
            ("describeActive", BrowserAgentScripts.describeActive()),
            ("click", BrowserAgentScripts.click(id: 3)),
            ("type", BrowserAgentScripts.typeText(id: 3, text: "hello \"world\"\nline2", clear: true)),
            ("key", BrowserAgentScripts.pressKey("Enter")),
            ("keySpace", BrowserAgentScripts.pressKey("Space")),
            ("scroll", BrowserAgentScripts.scroll(direction: "down")),
            ("scrollTop", BrowserAgentScripts.scroll(direction: "top", amount: 0.5)),
            ("text", BrowserAgentScripts.getText()),
            ("center", BrowserAgentScripts.centerOnScreen(id: 3)),
            ("history", BrowserAgentScripts.history(direction: "back")),
            ("badKey", BrowserAgentScripts.pressKey("F13")),
            ("badDirection", BrowserAgentScripts.history(direction: "sideways")),
            ("longText", BrowserAgentScripts.typeText(id: 3, text: String(repeating: "\"\\\n🐈", count: 3_000), clear: false)),
        ]
    }

    func testEveryScriptIsOneBalancedExpressionWithinTheCap() {
        for (name, source) in sampleScripts {
            XCTAssertFalse(source.isEmpty, name)
            XCTAssertLessThanOrEqual(source.count, BrowserAgentScripts.maxScriptLength, name)
            XCTAssertTrue(source.hasPrefix("(() =>"), "\(name) should be one IIFE expression")
            XCTAssertTrue(source.hasSuffix(")()"), "\(name) should close the IIFE")
            XCTAssertTrue(isBalanced(source), "\(name) has unbalanced parentheses or braces")
        }
    }

    func testJSStringRoundTripsQuotesNewlinesAndUnicode() throws {
        let samples = [
            "hello \"world\"\nline2",
            "back\\slash and 'single'",
            "café 🐈 日本語",
            "tab\there and \u{2028} separator \u{2029}",
        ]
        for sample in samples {
            let literal = BrowserAgentScripts.jsString(sample)
            XCTAssertTrue(literal.hasPrefix("\""), sample)
            XCTAssertTrue(literal.hasSuffix("\""), sample)
            XCTAssertFalse(literal.contains("\n"), "newlines must be escaped")
            XCTAssertFalse(literal.contains("\u{2028}"), "line separators must be escaped")

            let data = try XCTUnwrap(literal.data(using: .utf8))
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
            XCTAssertEqual(decoded, sample)
        }
    }

    func testTypeTextEmbedsTheArgumentAsOneEscapedLiteral() {
        let text = "say \"hi\"\nnew line"
        let source = BrowserAgentScripts.typeText(id: 7, text: text, clear: true)
        XCTAssertTrue(source.contains(BrowserAgentScripts.jsString(text)))
        XCTAssertFalse(source.contains(text), "the raw argument must not appear in the script")
        XCTAssertTrue(source.contains("no element with id 7"))
    }

    func testSnapshotAssignsStableIDsWalkingShadowRoots() {
        let source = BrowserAgentScripts.snapshot()
        XCTAssertTrue(source.contains("data-peeky-id"))
        XCTAssertTrue(source.contains("__peekyNext"))
        XCTAssertTrue(source.contains("shadowRoot"))
        XCTAssertTrue(source.contains("const LIMIT = 120"))
        XCTAssertTrue(source.contains("2500"))
    }

    func testDumpScriptsForManualRun() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENT_JS_DUMP_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set AGENT_JS_DUMP_DIR to a folder to write the scripts there for manual runs.")
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let scripts: [(name: String, source: String)] = [
            ("snapshot.js", BrowserAgentScripts.snapshot()),
            ("describe.js", BrowserAgentScripts.describe(id: 3)),
            ("describeActive.js", BrowserAgentScripts.describeActive()),
            ("click.js", BrowserAgentScripts.click(id: 3)),
            ("type.js", BrowserAgentScripts.typeText(id: 3, text: "hello \"world\"\nline2", clear: true)),
            ("key.js", BrowserAgentScripts.pressKey("Enter")),
            ("scroll.js", BrowserAgentScripts.scroll(direction: "down")),
            ("text.js", BrowserAgentScripts.getText()),
            ("center.js", BrowserAgentScripts.centerOnScreen(id: 3)),
            ("history.js", BrowserAgentScripts.history(direction: "back")),
        ]
        for (name, source) in scripts {
            XCTAssertFalse(source.isEmpty, name)
            try source.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Scripts are checked by eye for quotes and regexes, so this only needs
    /// to catch a genuinely lopsided script; the sample arguments never put
    /// parentheses or braces inside the embedded strings.
    private func isBalanced(_ source: String) -> Bool {
        var parentheses = 0
        var braces = 0
        for character in source {
            switch character {
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "{": braces += 1
            case "}": braces -= 1
            default: break
            }
            if parentheses < 0 || braces < 0 { return false }
        }
        return parentheses == 0 && braces == 0
    }
}
