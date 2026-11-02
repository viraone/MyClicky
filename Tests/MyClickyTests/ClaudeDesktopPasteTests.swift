import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class ClaudeDesktopPasteTests: XCTestCase {
    private func candidate(_ label: String, minY: CGFloat) -> ClaudeDesktopPaste.PromptCandidate {
        .init(label: label, frame: NSRect(x: 480, y: minY, width: 1100, height: 33))
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("peeky-test-\(UUID().uuidString)"))
    }

    private func samplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.orange.setFill()
            rect.fill()
            return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    // MARK: - Finding the chat box

    func testChatBoxIsFoundWhileClaudeIsBusyOrIdle() {
        let busy = ClaudeDesktopPaste.pickPromptBox([candidate("Prompt ⏎ to send, ⌘⏎ to queue for later", minY: 40)])
        let idle = ClaudeDesktopPaste.pickPromptBox([candidate("Write your prompt to Claude Reply", minY: 40)])
        XCTAssertNotNil(busy)
        XCTAssertNotNil(idle)
    }

    func testLabelledPromptBoxBeatsALowerUnlabelledTextArea() {
        let picked = ClaudeDesktopPaste.pickPromptBox([
            candidate("Search", minY: 10),
            candidate("Write your prompt to Claude", minY: 300),
        ])
        XCTAssertEqual(picked?.label, "Write your prompt to Claude")
    }

    func testLowestTextAreaWinsWhenNothingSaysPrompt() {
        let picked = ClaudeDesktopPaste.pickPromptBox([
            candidate("Search", minY: 700),
            candidate("Message", minY: 40),
        ])
        XCTAssertEqual(picked?.label, "Message")
    }

    func testFocusedStateSurvivesPicking() {
        var box = candidate("Write your prompt to Claude", minY: 40)
        box.isFocused = true
        XCTAssertEqual(ClaudeDesktopPaste.pickPromptBox([candidate("Search", minY: 500), box])?.isFocused, true)
        XCTAssertEqual(ClaudeDesktopPaste.pickPromptBox([candidate("Write your prompt to Claude", minY: 40)])?.isFocused, false)
    }

    func testNoTextAreasMeansNoChatBox() {
        XCTAssertNil(ClaudeDesktopPaste.pickPromptBox([]))
    }

    // MARK: - The clipboard

    func testEntireScreenClipboardCountsAsAnImage() {
        // ENTIRE SCREEN writes PNG alone.
        let board = privatePasteboard()
        board.clearContents()
        board.setData(samplePNG(), forType: .png)
        XCTAssertTrue(ClaudeDesktopPaste.clipboardHasImage(board))
    }

    func testCaptureClipboardWithDictationTextCountsAsAnImage() {
        // CAPTURE writes TIFF + PNG (+ the dictated words) as one item.
        let board = privatePasteboard()
        board.clearContents()
        let item = NSPasteboardItem()
        let png = samplePNG()
        item.setData(NSBitmapImageRep(data: png)!.tiffRepresentation!, forType: .tiff)
        item.setData(png, forType: .png)
        item.setString("these are my words", forType: .string)
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertTrue(ClaudeDesktopPaste.clipboardHasImage(board))
    }

    func testTextOnlyClipboardIsNotAnImage() {
        let board = privatePasteboard()
        board.clearContents()
        board.setString("just words", forType: .string)
        XCTAssertFalse(ClaudeDesktopPaste.clipboardHasImage(board))
    }

    func testEmptyClipboardIsNotAnImage() {
        let board = privatePasteboard()
        board.clearContents()
        XCTAssertFalse(ClaudeDesktopPaste.clipboardHasImage(board))
    }

    // MARK: - Spotting the pasted picture

    func testRemoveButtonOnAnAttachedPictureIsRecognised() {
        XCTAssertTrue(ClaudeDesktopPaste.isAttachmentRemoveButton(description: "Remove 1793602240259_image.png"))
        XCTAssertFalse(ClaudeDesktopPaste.isAttachmentRemoveButton(description: "Send message"))
        XCTAssertFalse(ClaudeDesktopPaste.isAttachmentRemoveButton(description: "Low res"))
    }
}
