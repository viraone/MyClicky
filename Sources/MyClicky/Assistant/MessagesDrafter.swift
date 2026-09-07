import AppKit
import OSLog

/// Screen-aware dictation for Messages: with a conversation open, the user
/// says the gist ("tell him I'm running ten late") and Claude writes the
/// text the way they'd text it — short, casual, answering what's on
/// screen — into the compose box. Nothing is sent here.
@MainActor
enum MessagesDrafter {
    private static let log = Logger(subsystem: "com.myclicky", category: "messagesdraft")

    private static let system = """
    You write text messages for someone dictating by voice. They give the \
    gist — casual, spoken, with speech-to-text errors — and you write the \
    message they'd actually send.

    Voice: this is a text, not an email. One to three short sentences, the \
    way a real person texts a friend or family: lowercase-casual is fine, \
    contractions, no greeting, no sign-off, no "I hope you're well". Match \
    the tone of the conversation shown — playful back to playful, plain back \
    to plain. An emoji only if the gist clearly calls for one. Never invent \
    facts, times or promises the person didn't say.

    Replies: when recent messages are shown, answer the last thing the other \
    person said specifically.

    Revisions: when a current draft is provided, the person is talking to \
    you about it, not dictating more — "shorter", "add that I'll bring \
    food", "actually it's Thursday not Tuesday" means change that in the \
    draft and return the whole revised text. Never paste their instruction \
    or apology into the message.

    Erasing: when they want the draft gone — "erase that", "get rid of \
    that message", "delete it", "clear it out", "scrap that", "start over" \
    — even if they quote the draft's words while asking, or ramble, reply \
    {"action": "erase"} and nothing else. Only a request to remove the \
    WHOLE draft is an erase; "delete the second sentence" is a revision.

    Undoing: when they want the LAST change reverted rather than the draft \
    rewritten — "undo that", "undo", "put it back", "revert that", "go back \
    to what it was", "never mind, undo" — reply {"action": "undo"} and \
    nothing else. This restores the previous text exactly; don't try to \
    reconstruct it yourself.

    Reply with JSON only: {"action": "write", "text": "<the message>"}, \
    {"action": "erase"}, or {"action": "undo"}.
    """

    enum Outcome: Equatable {
        case write(String)
        case erase
        case undo
    }

    static func write(gist: String, recipient: String, transcript: [String], currentDraft: String?,
                      senderName: String, claude: AnthropicService) async throws -> Outcome {
        var payload = "Gist, as spoken: \"\(gist)\"\n\nSender: \(senderName)\nConversation with: \(recipient)\n"
        if let currentDraft, !currentDraft.isEmpty { payload += "\nCurrent draft:\n<draft>\n\(currentDraft)\n</draft>\n" }
        if !transcript.isEmpty {
            payload += "\nRecent messages on screen, oldest first (the sender's own may be among them):\n<messages>\n"
                     + transcript.joined(separator: "\n") + "\n</messages>\n"
        }
        // A one-line text in the sender's voice doesn't need deep thought, and the
        // user is watching the compose box wait: low effort is the latency knob.
        let json = try await claude.requestJSON(system: system, userText: payload, maxTokens: 600, timeout: 45, effort: "low")
        let action = (json["action"] as? String)?.lowercased()
        if action == "erase" { return .erase }
        if action == "undo" { return .undo }
        guard let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AnthropicService.ServiceError.emptyAnswer
        }
        return .write(text)
    }
}
