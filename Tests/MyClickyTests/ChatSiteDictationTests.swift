import XCTest
@testable import MyClicky

@MainActor
final class ChatSiteDictationTests: XCTestCase {
    // MARK: Site matching

    func testKnownSitesResolveFromURL() {
        XCTAssertEqual(ChatSiteActions.site(for: "https://aistudio.google.com/prompts/1U0ZFlkmqpokCI4WKlUKgT8ugjjHCZUjA")?.name, "AI Studio")
        XCTAssertEqual(ChatSiteActions.site(for: "https://chatgpt.com/c/abc")?.name, "ChatGPT")
        XCTAssertEqual(ChatSiteActions.site(for: "https://gemini.google.com/app")?.name, "Gemini")
        XCTAssertEqual(ChatSiteActions.site(for: "https://claude.ai/new")?.name, "Claude")
    }

    func testOtherSitesDoNotMatch() {
        XCTAssertNil(ChatSiteActions.site(for: "https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertNil(ChatSiteActions.site(for: "https://github.com/viraone/MyClicky"))
    }

    // MARK: Revision vs. more dictation

    func testCorrectionsAreRevisions() {
        XCTAssertTrue(AssistantController.isPromptRevision("actually make that Python not JavaScript"))
        XCTAssertTrue(AssistantController.isPromptRevision("no wait, change that to Tuesday"))
        XCTAssertTrue(AssistantController.isPromptRevision("um, take out the last sentence"))
        XCTAssertTrue(AssistantController.isPromptRevision("also ask it to include tests"))
        XCTAssertTrue(AssistantController.isPromptRevision("I meant the second one"))
        XCTAssertTrue(AssistantController.isPromptRevision("shorter"))
    }

    func testPlainSpeechKeepsAppending() {
        XCTAssertFalse(AssistantController.isPromptRevision("how does DNS resolution work"))
        XCTAssertFalse(AssistantController.isPromptRevision("and then explain the caching part"))
        XCTAssertFalse(AssistantController.isPromptRevision("not sure how this works, can you explain"))
        XCTAssertFalse(AssistantController.isPromptRevision("so do you see my page"))
    }

    // MARK: Segment tidying

    func testFirstSegmentIsCapitalised() {
        XCTAssertEqual(AssistantController.tidyPromptSegment("how does DNS work", appendingTo: ""), "How does DNS work")
    }

    func testAppendedSegmentGetsAFullStopBetween() {
        XCTAssertEqual(AssistantController.tidyPromptSegment("and why is it cached", appendingTo: "How does DNS work"),
                       "How does DNS work. And why is it cached")
    }

    func testExistingPunctuationIsNotDoubled() {
        XCTAssertEqual(AssistantController.tidyPromptSegment("explain caching", appendingTo: "How does DNS work?"),
                       "How does DNS work? Explain caching")
        XCTAssertEqual(AssistantController.tidyPromptSegment("keep it short", appendingTo: "Explain DNS, "),
                       "Explain DNS, Keep it short")
    }

    func testEmptySegmentLeavesTextAlone() {
        XCTAssertEqual(AssistantController.tidyPromptSegment("   ", appendingTo: "Hello"), "Hello")
    }
}
