import AppKit
import OSLog

/// Screen-aware dictation for Gmail: the user says the gist of an email
/// ("tell them I'm interested in the sales role and want to hear more"),
/// Claude writes it in their voice using what the compose window already
/// shows — who it's to, any subject, the thread being replied to — and the
/// result is typed into the compose. Nothing is sent here.
@MainActor
enum GmailDrafter {
    private static let log = Logger(subsystem: "com.myclicky", category: "gmaildraft")
    private static let isGmail: (String) -> Bool = { $0.contains("mail.google.com") }

    /// What the open compose window currently holds.
    struct Compose {
        var to: String
        var subject: String
        /// The user's own part of the body — anything above a quoted reply.
        var body: String
        /// The message(s) being replied to, if this is a reply.
        var thread: String
        /// Gmail appended the user's signature block; the draft stops above it.
        var hasSignature: Bool
    }

    struct Draft {
        var subject: String
        var body: String
    }

    /// Reads the visible compose window in the Gmail tab. nil when no
    /// compose is open (or JavaScript from Apple Events is off).
    static func openCompose(recipientHint: String? = nil) -> Compose? {
        let js = """
        (function(){
          var vis=function(s){var a=Array.prototype.slice.call(document.querySelectorAll(s)).filter(function(e){return e.offsetParent!==null;});return a[a.length-1];};
          var body=vis("div[aria-label='Message Body']"); if(!body){return 'none';}
          var subj=vis("input[name=subjectbox]");
          var chips=Array.prototype.slice.call(document.querySelectorAll("div[role=listbox] div[data-hovercard-id], span[email], input[name=to]"))
            .filter(function(e){return e.offsetParent!==null;})
            .map(function(e){return e.getAttribute('data-name')||e.getAttribute('name')||e.getAttribute('data-hovercard-id')||e.getAttribute('email')||e.value||'';})
            .filter(function(x){return x.length>0;});
          var q=body.querySelector('.gmail_quote');
          var sig=body.querySelector('div[data-smartmail=gmail_signature]');
          var own=body.innerText; if(q){own=own.replace(q.innerText,'');} if(sig){own=own.replace(sig.innerText,'');}
          var thread=Array.prototype.slice.call(document.querySelectorAll('div.a3s')).filter(function(e){return e.offsetParent!==null;}).map(function(e){return e.innerText;}).join(' ----- ');
          if(!thread && q){thread=q.innerText;}
          return JSON.stringify({to:chips.join(', '),subject:subj?subj.value:'',body:own,thread:thread.slice(0,12000),signature:sig?'yes':'no'});
        })()
        """
        guard let raw = BrowserTabReader.runJavaScript(js, inTabMatching: isGmail), raw != "none",
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        let chips = json["to"] ?? ""
        // Chips often carry only the address; the name Clicky resolved reads better in a greeting.
        let to = (recipientHint?.isEmpty == false && !chips.contains("<")) ? recipientHint! : chips
        return Compose(to: to, subject: json["subject"] ?? "",
                       body: (json["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       thread: json["thread"] ?? "",
                       hasSignature: json["signature"] == "yes")
    }

    private static let system = """
    You write emails for someone who dictates by voice. They give you the \
    gist — casual, spoken, sometimes rambling, with speech-to-text errors — \
    and you turn it into the email they would have written themselves.

    Voice: first person, natural, plain and warm. Short sentences. No \
    corporate filler, no "I hope this email finds you well", no flattery, no \
    exclamation marks unless the gist is clearly excited. Sound like a real \
    person, not a template. Never use placeholders like [Your Name] or \
    [Company] — use what you're given, or leave it out.

    Shape: a short greeting using the recipient's first name when known \
    ("Hi Sam,"), the body in one to three short paragraphs, a one-line \
    sign-off, then the sender's first name on its own line. Say what the gist \
    says — do not invent facts, dates, qualifications or commitments the \
    person didn't mention.

    Replies: when a thread is provided, answer it specifically — refer to \
    what they actually wrote. Keep the existing subject.

    Revisions: when a current draft is provided and the gist is a change to \
    it ("shorter", "add that I'm free Friday", "less formal"), return the \
    full revised email, keeping everything not asked to change.

    Reply with JSON only: {"subject": "<subject line, 2-7 words>", \
    "body": "<the email, with real line breaks>"}.

    If told the compose has a signature, end with the sign-off line only \
    ("Thanks," / "Best,") and no name — the signature supplies it.
    """

    /// Writes the email. `senderName` is the Mac account's full name; the
    /// sign-off uses the first word of it.
    static func write(gist: String, compose: Compose, senderName: String, claude: AnthropicService) async throws -> Draft {
        var payload = "Gist, as spoken: \"\(gist)\"\n\nSender's name: \(senderName)\n"
        if !compose.to.isEmpty { payload += "To: \(compose.to)\n" }
        if compose.hasSignature { payload += "The compose has a signature block below the body.\n" }
        if !compose.subject.isEmpty { payload += "Current subject: \(compose.subject)\n" }
        if !compose.body.isEmpty { payload += "\nCurrent draft:\n<draft>\n\(compose.body)\n</draft>\n" }
        if !compose.thread.isEmpty { payload += "\nThread being replied to:\n<thread>\n\(compose.thread)\n</thread>\n" }

        let json = try await claude.requestJSON(system: system, userText: payload, maxTokens: 2_000, timeout: 60)
        guard let body = json["body"] as? String, !body.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AnthropicService.ServiceError.emptyAnswer
        }
        let subject = (json["subject"] as? String) ?? compose.subject
        return Draft(subject: compose.subject.isEmpty ? subject : compose.subject, body: body)
    }

    /// Types the draft into the open compose: the subject only if the field
    /// is empty, the body replacing whatever the user had written above any
    /// quoted reply. Uses insertText so Gmail sees it as typing and keeps
    /// its own autosave/undo working.
    static func fill(_ draft: Draft, replaceSubject: Bool) -> Bool {
        guard let subjectLiteral = jsString(draft.subject), let bodyLiteral = jsString(draft.body) else { return false }
        let js = """
        (function(){
          var vis=function(s){var a=Array.prototype.slice.call(document.querySelectorAll(s)).filter(function(e){return e.offsetParent!==null;});return a[a.length-1];};
          var body=vis("div[aria-label='Message Body']"); if(!body){return 'none';}
          var subj=vis("input[name=subjectbox]");
          if(subj && \(replaceSubject ? "true" : "false")){subj.focus();subj.select();document.execCommand('insertText',false,\(subjectLiteral));}
          body.focus();
          var r=document.createRange(); r.selectNodeContents(body);
          var stop=body.querySelector('div[data-smartmail=gmail_signature], .gmail_quote'); if(stop){r.setEndBefore(stop);}
          var sel=window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
          document.execCommand('insertText',false,\(bodyLiteral)+(stop?'\\n\\n':''));
          return 'ok';
        })()
        """
        let result = BrowserTabReader.runJavaScript(js, inTabMatching: isGmail)
        if result != "ok" { log.error("fill failed: \(result ?? "nil", privacy: .public)") }
        return result == "ok"
    }

    private static func jsString(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        // "[\"…\"]" → "\"…\""
        return String(array.dropFirst().dropLast())
    }
}
