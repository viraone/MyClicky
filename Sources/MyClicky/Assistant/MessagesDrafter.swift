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

    Reply with JSON only: {"text": "<the message>"}.
    """

    static func write(gist: String, recipient: String, transcript: [String], currentDraft: String?,
                      senderName: String, claude: AnthropicService) async throws -> String {
        var payload = "Gist, as spoken: \"\(gist)\"\n\nSender: \(senderName)\nConversation with: \(recipient)\n"
        if let currentDraft, !currentDraft.isEmpty { payload += "\nCurrent draft:\n<draft>\n\(currentDraft)\n</draft>\n" }
        if !transcript.isEmpty {
            payload += "\nRecent messages on screen, oldest first (the sender's own may be among them):\n<messages>\n"
                     + transcript.joined(separator: "\n") + "\n</messages>\n"
        }
        let json = try await claude.requestJSON(system: system, userText: payload, maxTokens: 600, timeout: 45)
        guard let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AnthropicService.ServiceError.emptyAnswer
        }
        return text
    }
}
