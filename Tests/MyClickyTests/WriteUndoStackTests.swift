import XCTest
@testable import MyClicky

/// A fake field: identity by name, value held in memory, no Accessibility.
@MainActor
private final class FakeField: WriteUndoTarget {
    let name: String
    var value: String
    var valid = true
    /// What `restore` should report; `.success` writes the value through.
    var restoreResult: BackgroundWriteResult = .success
    private(set) var restores: [String] = []

    init(_ name: String, value: String = "") {
        self.name = name
        self.value = value
    }

    var undoKey: AnyHashable { name }
    var isValid: Bool { valid }
    func currentValue() -> String? { valid ? value : nil }
    func restore(_ value: String) -> BackgroundWriteResult {
        restores.append(value)
        if restoreResult.landed { self.value = value }
        return restoreResult
    }
    var frame: CGRect? { nil }

    /// Mimics `AXActions.writeTextInBackground` on this field: reads the
    /// previous value, sets, and records on `stack` unless `undoable` is off.
    @discardableResult
    func write(_ text: String, on stack: WriteUndoStack, undoable: Bool = true) -> BackgroundWriteResult {
        let previous = value
        value = text
        let result: BackgroundWriteResult = previous == text ? .suspectedNoop : .success
        if undoable {
            stack.record(target: self, previousValue: previous, newValue: text, label: name)
        }
        return result
    }
}

@MainActor
final class WriteUndoStackTests: XCTestCase {

    func testRealChangeIsPushedAndUndone() {
        let stack = WriteUndoStack(capacity: 20)
        let field = FakeField("Messages · Dino Dad")
        XCTAssertEqual(field.write("on my way", on: stack), .success)
        XCTAssertEqual(stack.count, 1)

        let outcome = stack.undoLast()
        XCTAssertEqual(outcome, .restored(label: "Messages · Dino Dad", previousValue: "", forced: false))
        XCTAssertEqual(field.value, "")
        XCTAssertEqual(field.restores, [""])
        XCTAssertTrue(stack.isEmpty)
    }

    func testNoopWriteIsNotPushed() {
        let stack = WriteUndoStack()
        let field = FakeField("f", value: "same")
        XCTAssertEqual(field.write("same", on: stack), .suspectedNoop)
        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(stack.undoLast(), .nothingToUndo)
    }

    func testLineEndingsOnlyDifferenceIsNoop() {
        let stack = WriteUndoStack()
        let field = FakeField("f", value: "a\r\nb")
        stack.record(target: field, previousValue: "a\r\nb", newValue: "a\nb", label: "f")
        XCTAssertTrue(stack.isEmpty)
    }

    func testTwoWritesTwoUndosThenNothing() {
        let stack = WriteUndoStack()
        let field = FakeField("f")
        field.write("first", on: stack)
        field.write("second", on: stack)
        XCTAssertEqual(stack.count, 2)

        XCTAssertEqual(stack.undoLast(), .restored(label: "f", previousValue: "first", forced: false))
        XCTAssertEqual(field.value, "first")
        XCTAssertEqual(stack.undoLast(), .restored(label: "f", previousValue: "", forced: false))
        XCTAssertEqual(field.value, "")
        XCTAssertEqual(stack.undoLast(), .nothingToUndo)
        XCTAssertEqual(UndoWriteOutcome.nothingToUndo.message, "Nothing to undo.")
    }

    func testUndoWriteItselfIsNotRecorded() {
        let stack = WriteUndoStack()
        let field = FakeField("f")
        field.write("hello", on: stack)
        _ = stack.undoLast()
        // The restore went through the target with undo recording off, so
        // there is no redo entry to pop.
        XCTAssertTrue(stack.isEmpty)
    }

    func testStreamingPartialsCoalesceIntoOneEntry() {
        let stack = WriteUndoStack()
        let field = FakeField("Messages · Dad")
        // ComposeStream.begin/update: partials go in with undo off.
        stack.beginCoalescing(field, previousValue: "", label: "Messages · Dad")
        field.write("on", on: stack, undoable: false)
        field.write("on my", on: stack, undoable: false)
        field.write("on my way", on: stack, undoable: false)
        XCTAssertTrue(stack.isEmpty)
        XCTAssertTrue(stack.isCoalescing)

        // Claude's polished sentence replaces the preview: one entry, whose
        // previous value is the box *before* the preview, not the last partial.
        field.write("On my way!", on: stack)
        XCTAssertEqual(stack.count, 1)
        XCTAssertFalse(stack.isCoalescing)
        XCTAssertEqual(stack.last?.previousValue, "")
        XCTAssertEqual(stack.last?.newValue, "On my way!")

        XCTAssertEqual(stack.undoLast(), .restored(label: "Messages · Dad", previousValue: "", forced: false))
        XCTAssertEqual(field.value, "")
    }

    func testPolishedTextIdenticalToPreviewStillUndoable() {
        let stack = WriteUndoStack()
        let field = FakeField("f")
        stack.beginCoalescing(field, previousValue: "")
        field.write("ok see you", on: stack, undoable: false)
        // Claude returned the preview verbatim → the primitive reports a
        // no-op, but relative to the coalesced start the field did change.
        XCTAssertEqual(field.write("ok see you", on: stack), .suspectedNoop)
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.last?.previousValue, "")
    }

    func testDiscardedPreviewEndsCoalescing() {
        let stack = WriteUndoStack()
        let field = FakeField("f", value: "")
        stack.beginCoalescing(field, previousValue: "")
        field.write("send", on: stack, undoable: false)
        // The words were a command: ComposeStream.clear() → endCoalescing.
        stack.endCoalescing(field)
        field.write("", on: stack, undoable: false)
        XCTAssertFalse(stack.isCoalescing)
        XCTAssertTrue(stack.isEmpty)

        // A later ordinary write is undone to its own previous value.
        field.write("later", on: stack)
        XCTAssertEqual(stack.last?.previousValue, "")
    }

    func testCoalescingIsPerTarget() {
        let stack = WriteUndoStack()
        let a = FakeField("a", value: "A0")
        let b = FakeField("b", value: "B0")
        stack.beginCoalescing(a, previousValue: "A0")
        a.write("A partial", on: stack, undoable: false)
        // A write to a different field is unaffected by a's pending preview.
        b.write("B1", on: stack)
        XCTAssertEqual(stack.last?.previousValue, "B0")
        XCTAssertTrue(stack.isCoalescing)
        a.write("A1", on: stack)
        XCTAssertEqual(stack.last?.previousValue, "A0")
        XCTAssertEqual(stack.count, 2)
    }

    func testCapDropsOldestEntries() {
        let stack = WriteUndoStack(capacity: 3)
        let field = FakeField("f")
        for i in 1...5 { field.write("v\(i)", on: stack) }
        XCTAssertEqual(stack.count, 3)
        XCTAssertEqual(stack.entries.map(\.previousValue), ["v2", "v3", "v4"])

        XCTAssertEqual(stack.undoLast(), .restored(label: "f", previousValue: "v4", forced: false))
        XCTAssertEqual(stack.undoLast(), .restored(label: "f", previousValue: "v3", forced: false))
        XCTAssertEqual(stack.undoLast(), .restored(label: "f", previousValue: "v2", forced: false))
        XCTAssertEqual(stack.undoLast(), .nothingToUndo)
    }

    func testUserTypedSinceIsForcedRevert() {
        let stack = WriteUndoStack()
        let field = FakeField("f", value: "before")
        field.write("peeky wrote this", on: stack)
        field.value = "peeky wrote this and then I typed more"

        let outcome = stack.undoLast()
        XCTAssertEqual(outcome, .restored(label: "f", previousValue: "before", forced: true))
        XCTAssertEqual(field.value, "before")
        XCTAssertTrue(outcome.message.contains("over what was typed since"))
    }

    func testInvalidTargetsArePrunedBeforeUndo() {
        let stack = WriteUndoStack()
        let gone = FakeField("gone")
        let alive = FakeField("alive")
        alive.write("keep", on: stack)
        gone.write("lost", on: stack)
        gone.valid = false

        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.undoLast(), .restored(label: "alive", previousValue: "", forced: false))
        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(gone.restores, [])
    }

    func testAllTargetsGoneIsNothingToUndo() {
        let stack = WriteUndoStack()
        let gone = FakeField("gone")
        gone.write("lost", on: stack)
        gone.valid = false
        XCTAssertEqual(stack.undoLast(), .nothingToUndo)
    }

    func testFailedWriteBackIsReportedAndPopped() {
        let stack = WriteUndoStack()
        let field = FakeField("f")
        field.write("x", on: stack)
        field.restoreResult = .verificationFailed

        XCTAssertEqual(stack.undoLast(), .failed(label: "f", .verificationFailed))
        XCTAssertEqual(field.value, "x")
        XCTAssertTrue(stack.isEmpty)
    }

    func testMessages() {
        XCTAssertEqual(UndoWriteOutcome.restored(label: "Messages · Dad", previousValue: "", forced: false).message,
                       "Undone — cleared the text I'd written in Messages · Dad.")
        XCTAssertEqual(UndoWriteOutcome.restored(label: "Notes", previousValue: "hi there", forced: false).message,
                       "Undone — put back “hi there” in Notes.")
        XCTAssertEqual(UndoWriteOutcome.targetGone(label: "Notes").message,
                       "Couldn't undo — the field in Notes isn't there any more.")
    }
}

@MainActor
final class BackgroundWriteResultTests: XCTestCase {
    func testLandedAndFallback() {
        XCTAssertTrue(BackgroundWriteResult.success.landed)
        XCTAssertTrue(BackgroundWriteResult.suspectedNoop.landed)
        XCTAssertFalse(BackgroundWriteResult.success.needsFallback)
        XCTAssertFalse(BackgroundWriteResult.suspectedNoop.needsFallback)
        for failure in [BackgroundWriteResult.verificationFailed, .elementNotWritable, .permissionDenied, .unsupportedTarget] {
            XCTAssertFalse(failure.landed)
            XCTAssertTrue(failure.needsFallback)
        }
    }
}

@MainActor
final class UndoPhraseTests: XCTestCase {
    func testUndoPhrasesMatch() {
        for phrase in ["undo", "Undo that", "undo it", "put it back", "put that back", "revert that", "revert",
                       "never mind, undo", "Peeky, undo that", "actually undo that", "oops undo", "take it back",
                       "change it back", "undo the last one", "Okay, undo that please.", "Un Undo that", "undo undo that", "Un— undo"] {
            XCTAssertTrue(AssistantController.isUndoIt(phrase), "should match: \(phrase)")
        }
    }

    func testDictationAndRevisionsDoNotMatch() {
        for phrase in ["undo the second sentence", "tell him to undo the changes on the server", "never mind",
                       "put it back on the shelf tomorrow", "revert the deployment and tell the team", "send it",
                       "erase that", "I'll put it back in the fridge when I get home"] {
            XCTAssertFalse(AssistantController.isUndoIt(phrase), "should not match: \(phrase)")
        }
    }
}

@MainActor
final class ConversationOpenPhraseTests: XCTestCase {
    func testOpenPhrasesYieldTheName() {
        let cases: [(String, String)] = [
            ("Can you bring up a text message with Jason Katz", "Jason Katz"),
            ("Open up a text message with Jason Katz", "Jason Katz"),
            ("Open up a message with Dino Dan", "Dino Dan"),
            ("open Dino Dad's conversation", "Dino Dad"),
            ("pull up my chat with Ben", "Ben"),
            ("Actually, open up a text with Dave please", "Dave"),
            ("show me the conversation with David Babu", "David Babu"),
            ("start a new message to Sam", "Sam"),
            ("hey peeky open the thread with mom", "Mom"),
        ]
        for (phrase, name) in cases {
            XCTAssertEqual(AssistantController.conversationOpenRequest(phrase), name, phrase)
        }
    }

    func testOtherCommandsAndDictationDoNotMatch() {
        for phrase in ["open Safari", "open Messages", "text him I'm running late", "send it",
                       "tell her the store is open till nine", "bring up the calendar",
                       "open the message and read it to me", "undo that", "erase that",
                       "show me my messages", "open a new tab"] {
            XCTAssertNil(AssistantController.conversationOpenRequest(phrase), "should not match: \(phrase)")
        }
    }
}
