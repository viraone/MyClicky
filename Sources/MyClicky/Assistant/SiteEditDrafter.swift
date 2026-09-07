import AppKit
import OSLog

/// Voice edits to a content box on the Mobile SDET study site. The user
/// has a box in edit mode and says what to change — "where it says X put
/// Y", "explain TCP here with an analogy", "make the second paragraph
/// shorter" — and Claude returns the box's new content.
@MainActor
enum SiteEditDrafter {
    private static let log = Logger(subsystem: "com.myclicky", category: "siteeditdraft")

    private static let system = """
    You edit one content box of a study site that teaches Mobile SDET \
    (iOS/Android test automation: Appium, XCUITest, pytest, HTTP, TCP/IP, \
    the OS) through a running "mall" analogy — a Citadel of suites where \
    engineers, couriers and clerks stand for processes, protocols and \
    tools. The site's author dictates edits by voice; transcripts are \
    casual and contain speech-to-text errors.

    You receive the box's kind and label, its current content, and the \
    spoken instruction. Return the box's complete new content.

    Kinds:
    - "insight" boxes hold HTML. Allowed tags: <br>, <strong>, <em>, <code>. \
      Nothing else — no <p>, headings, lists or attributes. Paragraph breaks \
      are a single <br>. Escape & < > in prose as &amp; &lt; &gt;.
      Labels tell you the voice: "Mall metaphor" boxes are narrative — the \
      analogy, in the same story world (Arthur the architect, Suite 101, \
      Suite 400 = Appium, couriers, clerks, stencils). "Silicon reality" \
      boxes state exactly what the machine does, technically precise. "Why \
      it matters" boxes give the engineering reason in a few sentences.
    - "code" boxes hold plain text for a <code> block: no HTML tags, but \
      escape & < > as &amp; &lt; &gt;. Preserve indentation and line breaks.

    Editing rules:
    - Targeted change ("where it says X replace with Y", "change Friday to \
      Saturday", "delete the last sentence"): change only that; keep every \
      other word, tag and line as it was. Speech-to-text will have mangled X \
      — match the phrase they meant, not the letters they got.
    - Additive ("add an analogy for the three-way handshake", "explain what \
      a port is here"): keep the existing content and append or weave in \
      the new material in the box's voice.
    - Rewrite ("explain this with an analogy", "make it simpler", \
      "shorter"): rewrite the whole box in its voice, keeping the facts.
    - Never include the instruction itself, commentary, or a preamble in \
      the content. Never invent technical facts; when unsure, keep the \
      original wording.

    Reply with JSON only: {"html": "<the new content>", "summary": "<one short \
    sentence saying what changed, for the author to hear>"}.
    """

    struct Result {
        let html: String
        let summary: String
    }

    static func rewrite(box: SiteEditActions.Box, instruction: String, claude: AnthropicService) async throws -> Result {
        let payload = """
        <box kind="\(box.kind)" label="\(box.label)" id="\(box.id)">
        \(box.html)
        </box>
        <instruction>\(instruction)</instruction>
        """
        let json = try await claude.requestJSON(system: system, userText: payload, maxTokens: 3_000, timeout: 60, effort: "low")
        guard let html = json["html"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("no html in reply: \(String(describing: json).prefix(200), privacy: .private)")
            throw AnthropicService.ServiceError.emptyAnswer
        }
        return Result(html: html, summary: json["summary"] as? String ?? "Updated the box.")
    }
}
