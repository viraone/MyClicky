import XCTest
@testable import MyClicky

final class AnswerDecodingTests: XCTestCase {
    private func decode(_ s: String) -> AssistantAnswer? { AnthropicService.decodeAnswer(s) }

    func testStrictJSONWithBox() {
        let a = decode(#"{"answer": "The blue Save button.", "box_2d": [100, 200, 150, 300]}"#)
        XCTAssertEqual(a?.text, "The blue Save button.")
        XCTAssertEqual(a?.highlight, CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.05))
    }

    func testStrictJSONNullBox() {
        let a = decode(#"{"answer": "It's a login form.", "box_2d": null}"#)
        XCTAssertEqual(a?.text, "It's a login form.")
        XCTAssertNil(a?.highlight)
    }

    func testMarkdownFencesAreTolerated() {
        let a = decode("```json\n{\"answer\": \"Fenced.\", \"box_2d\": null}\n```")
        XCTAssertEqual(a?.text, "Fenced.")
    }

    /// The bug from the field: quoting a code comment with unescaped double
    /// quotes makes the object invalid JSON. The answer must survive.
    func testUnescapedQuotesInsideAnswerStillDecode() {
        let a = decode(#"{"answer": "Line 146 says "retry once" and line 148 says "give up".", "box_2d": null}"#)
        XCTAssertEqual(a?.text, #"Line 146 says "retry once" and line 148 says "give up"."#)
        XCTAssertNil(a?.highlight)
    }

    func testUnescapedQuotesKeepTheBox() {
        let a = decode(#"{"answer": "The "Submit" button.", "box_2d": [0, 0, 500, 1000]}"#)
        XCTAssertEqual(a?.text, #"The "Submit" button."#)
        XCTAssertEqual(a?.highlight, CGRect(x: 0, y: 0, width: 1, height: 0.5))
    }

    func testRawNewlinesInsideAnswer() {
        let a = decode("{\"answer\": \"First line.\nSecond line.\", \"box_2d\": null}")
        XCTAssertEqual(a?.text, "First line.\nSecond line.")
    }

    func testTruncatedObjectStillYieldsPartialAnswer() {
        let a = decode(#"{"answer": "The comments explain the retry loop and"#)
        XCTAssertEqual(a?.text, "The comments explain the retry loop and")
        XCTAssertNil(a?.highlight)
    }

    func testProseWithoutWrapperIsTheAnswer() {
        let a = decode("Those comments describe why the loop retries on 429.")
        XCTAssertEqual(a?.text, "Those comments describe why the loop retries on 429.")
        XCTAssertNil(a?.highlight)
    }

    func testEscapedSequencesAreUnescapedOnLenientPath() {
        let a = decode(#"{"answer": "He wrote \"x\"\nthen "y"", "box_2d": null}"#)
        XCTAssertEqual(a?.text, "He wrote \"x\"\nthen \"y\"")
    }

    func testGenuinelyEmptyIsNil() {
        XCTAssertNil(decode(""))
        XCTAssertNil(decode("   \n"))
        XCTAssertNil(decode(#"{"answer": "", "box_2d": null}"#))
        XCTAssertNil(decode(#"{"answer": null, "box_2d": null}"#))
    }

    func testEnvelopeReportsNoTextWhenOnlyThinking() {
        let payload = #"{"stop_reason": "max_tokens", "content": [{"type": "thinking", "thinking": "..."}]}"#
        let env = AnthropicService.envelope(from: Data(payload.utf8))
        XCTAssertNil(env.text)
        XCTAssertEqual(env.stopReason, "max_tokens")
        XCTAssertEqual(env.blockTypes, ["thinking"])
    }

    func testEnvelopeJoinsTextBlocks() {
        let payload = #"{"stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": "..."}, {"type": "text", "text": "{\"answer\": \"a\","}, {"type": "text", "text": " \"box_2d\": null}"}]}"#
        let env = AnthropicService.envelope(from: Data(payload.utf8))
        XCTAssertEqual(env.text, #"{"answer": "a", "box_2d": null}"#)
        XCTAssertEqual(AnthropicService.decodeAnswer(env.text!)?.text, "a")
    }
}
