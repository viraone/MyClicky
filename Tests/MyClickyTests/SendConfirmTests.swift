import XCTest
@testable import MyClicky

@MainActor
final class SendConfirmTests: XCTestCase {
    func testSpokenYesAnswers() {
        for phrase in ["yes", "Yes.", "yeah send it", "send it", "go ahead", "okay do it", "Peeky, send it",
                       "yes send the message", "sure", "confirm", "Ye yes"] {
            XCTAssertEqual(AssistantController.spokenConfirmAnswer(phrase), true, phrase)
        }
    }

    func testSpokenNoAnswers() {
        for phrase in ["no", "No!", "cancel", "never mind", "don't send it", "wait", "hold on", "nope cancel that",
                       "okay cancel", "not yet"] {
            XCTAssertEqual(AssistantController.spokenConfirmAnswer(phrase), false, phrase)
        }
    }

    func testSpeechThatIsNotAnAnswerFallsThrough() {
        for phrase in ["", "actually tell him I'll be there at seven", "yes I will bring the dog with me tomorrow",
                       "open a conversation with Dino Dad", "erase that", "undo that", "no way I am going there"] {
            XCTAssertNil(AssistantController.spokenConfirmAnswer(phrase), phrase)
        }
    }

    func testTrailingSendCommandIsSeparatedFromMessage() {
        let cases = [
            ("Let's find time next week to meet in person Send it",
             "Let's find time next week to meet in person"),
            ("I will bring the prototype. Please send that now.",
             "I will bring the prototype."),
            ("Sounds good to me sent it please",
             "Sounds good to me"),
        ]
        for (utterance, expected) in cases {
            XCTAssertEqual(AssistantController.messageBeforeTrailingSendCommand(utterance), expected, utterance)
        }
    }

    func testOrdinaryMessageDoesNotBecomeTrailingSendCommand() {
        for phrase in ["send it", "Please send it now", "I can send the file tomorrow", "Tell him to send it tomorrow"] {
            XCTAssertNil(AssistantController.messageBeforeTrailingSendCommand(phrase), phrase)
        }
    }

    func testConfirmFieldEncodingKeepsOneLinePerMessage() {
        let encoded = AssistantController.encodeConfirmField("Send to Dino Dad?\n\nSee you\tat 7\r\nbring snacks")
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertFalse(encoded.contains("\r"))
        XCTAssertFalse(encoded.contains("\t"))
        XCTAssertEqual(encoded.replacingOccurrences(of: "\u{2028}", with: "\n"),
                       "Send to Dino Dad?\n\nSee you at 7\nbring snacks")
    }
}
