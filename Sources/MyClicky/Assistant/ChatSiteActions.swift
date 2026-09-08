import AppKit
import OSLog

/// Dictation into the prompt box of an AI chat site in the browser — Google
/// AI Studio, ChatGPT, Claude, Gemini, Perplexity… With one of these tabs in
/// front, TALK types what's said, word for word, into the site's own input:
/// "how does DNS work" lands as text, "send it" presses Run/Send. Nothing is
/// rewritten by Claude unless the person is plainly correcting the box
/// ("actually, make that Python not JavaScript").
///
/// The DOM is the only state: what's in the box is the draft, read fresh
/// before every write. Uses `execCommand('insertText')` so the site's own
/// framework (Angular, React, ProseMirror) sees real input events and keeps
/// its send button / token counter in sync.
@MainActor
enum ChatSiteActions {
    private static let log = Logger(subsystem: "com.myclicky", category: "chatsite")

    struct Site: Equatable {
        let name: String
        let hosts: [String]
        /// Tried in order; the last visible, enabled match wins.
        let inputSelectors: [String]
        /// Send / Run buttons, tried in order. Falls back to a real Return.
        let submitSelectors: [String]

        func matches(_ url: String) -> Bool {
            hosts.contains { url.contains($0) }
        }
    }

    static let sites: [Site] = [
        Site(name: "AI Studio", hosts: ["aistudio.google.com"],
             inputSelectors: ["div.tiptap.ProseMirror[contenteditable='true']", "div.ProseMirror[contenteditable='true']",
                              "ms-prompt-input-wrapper textarea", "textarea[placeholder*='prompt' i]",
                              "textarea[aria-label*='prompt' i]", "textarea", "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label='Send message']", "button[aria-label*='Send' i]", "ms-run-button button",
                               "button[aria-label='Run']", "button[aria-label*='Run' i]", "button[type='submit']"]),
        Site(name: "ChatGPT", hosts: ["chatgpt.com", "chat.openai.com"],
             inputSelectors: ["#prompt-textarea", "div.ProseMirror[contenteditable='true']", "textarea"],
             submitSelectors: ["button[data-testid='send-button']", "button[aria-label*='Send' i]"]),
        Site(name: "Claude", hosts: ["claude.ai"],
             inputSelectors: ["div.ProseMirror[contenteditable='true']", "div[contenteditable='true']", "textarea"],
             submitSelectors: ["button[aria-label*='Send' i]"]),
        Site(name: "Gemini", hosts: ["gemini.google.com"],
             inputSelectors: [".ql-editor[contenteditable='true']", "rich-textarea div[contenteditable='true']",
                              "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label*='Send' i]", ".send-button"]),
        Site(name: "Perplexity", hosts: ["perplexity.ai"],
             inputSelectors: ["textarea", "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label*='Submit' i]", "button[type='submit']"]),
        Site(name: "Copilot", hosts: ["copilot.microsoft.com"],
             inputSelectors: ["textarea", "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label*='Submit' i]", "button[type='submit']"]),
        Site(name: "Grok", hosts: ["grok.com"],
             inputSelectors: ["textarea", "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label*='Submit' i]", "button[type='submit']"]),
        Site(name: "Poe", hosts: ["poe.com"],
             inputSelectors: ["textarea", "div[contenteditable='true']"],
             submitSelectors: ["button[aria-label*='Send' i]", "button[type='submit']"]),
    ]

    static func site(for url: String) -> Site? {
        sites.first { $0.matches(url) }
    }

    /// The chat site showing in the active tab of the frontmost browser, if
    /// any. The person is looking at it — that's what makes their words a
    /// prompt rather than a command.
    static func frontSite() -> Site? {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              BrowserTabReader.supportedBundleIDs.contains(front),
              let url = BrowserTabReader.activeTabURL() else { return nil }
        return site(for: url)
    }

    /// True while that site's tab is still the active one in a running browser.
    static func isOpen(_ site: Site) -> Bool {
        BrowserTabReader.runningBrowser(withTabMatching: site.matches) != nil
    }

    /// What the prompt box holds right now; nil when the box can't be found
    /// (or JavaScript from Apple Events is off in the browser).
    static func read(_ site: Site) -> String? {
        let js = """
        (function(){
          \(finder(site))
          var el=find(); if(!el){return '\u{1}none';}
          return (el.value!==undefined)?el.value:el.innerText;
        })()
        """
        guard let raw = BrowserTabReader.runJavaScript(js, inTabMatching: site.matches), raw != "\u{1}none" else { return nil }
        return raw
    }

    /// Replaces the prompt box's contents with `text` (empty clears it) and
    /// verifies. Typed via insertText so the page sees it as keystrokes; a
    /// direct value set with input events is the fallback for boxes that
    /// ignore execCommand.
    static func write(_ text: String, into site: Site) -> Bool {
        guard let literal = jsString(text) else { return false }
        let js = """
        (function(){
          \(finder(site))
          var el=find(); if(!el){return 'none';}
          var T=\(literal);
          var val=function(){return (el.value!==undefined)?el.value:el.innerText;};
          el.focus();
          if(el.tagName==='TEXTAREA'||el.tagName==='INPUT'){el.select();}
          else{var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);}
          try{ if(T===''){document.execCommand('delete');} else {document.execCommand('insertText',false,T);} }catch(e){}
          if(val().trim()!==T.trim()){
            if(el.value!==undefined){
              var setter=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el),'value');
              if(setter&&setter.set){setter.set.call(el,T);}else{el.value=T;}
              el.dispatchEvent(new Event('input',{bubbles:true}));
              el.dispatchEvent(new Event('change',{bubbles:true}));
            } else {
              el.innerText=T;
              el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:T}));
            }
          }
          return val().trim()===T.trim()?'ok':'mismatch:'+val().slice(0,60);
        })()
        """
        let result = BrowserTabReader.runJavaScript(js, inTabMatching: site.matches)
        if result != "ok" { log.error("\(site.name, privacy: .public) write failed: \(result ?? "nil", privacy: .public)") }
        return result == "ok"
    }

    /// Runs the prompt: clicks the site's Send/Run button when one is
    /// enabled, otherwise focuses the box and presses a real Return with the
    /// browser in front. Returns how it was sent, nil on failure.
    static func submit(_ site: Site) -> String? {
        let js = """
        (function(){
          \(finder(site))
          var el=find(); if(!el){return 'none';}
          var sels=\(jsArray(site.submitSelectors));
          for(var i=0;i<sels.length;i++){
            var a=Array.prototype.slice.call(document.querySelectorAll(sels[i])).filter(function(b){
              return b.offsetParent!==null && !b.disabled && b.getAttribute('aria-disabled')!=='true';});
            if(a.length){a[a.length-1].click();return 'clicked';}
          }
          el.focus(); return 'focused';
        })()
        """
        guard let result = BrowserTabReader.runJavaScript(js, inTabMatching: site.matches), result != "none" else { return nil }
        if result == "clicked" { return "button" }
        guard let browser = BrowserTabReader.runningBrowser(withTabMatching: site.matches) else { return nil }
        browser.activate()
        usleep(150_000)
        KeyboardTyper.press(36) // Return
        return "return"
    }

    /// Screen frame of the prompt box (AppKit coordinates) for the ring.
    static func inputFrame(_ site: Site) -> CGRect? {
        let js = """
        (function(){
          \(finder(site))
          var el=find(); if(!el){return 'none';}
          var r=el.getBoundingClientRect();
          var chrome=window.outerHeight-window.innerHeight;
          return [window.screenX+r.left, window.screenY+chrome+r.top, r.width, r.height].join(',');
        })()
        """
        guard let raw = BrowserTabReader.runJavaScript(js, inTabMatching: site.matches), raw != "none" else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, let primary = NSScreen.screens.first else { return nil }
        // JS gives top-left-origin points on the primary display; AppKit is bottom-left.
        let top = parts[1], height = parts[3]
        return CGRect(x: parts[0], y: primary.frame.height - top - height, width: parts[2], height: height)
    }

    // MARK: - JS helpers

    private static func finder(_ site: Site) -> String {
        """
        var find=function(){var sels=\(jsArray(site.inputSelectors));
          for(var i=0;i<sels.length;i++){
            var a=Array.prototype.slice.call(document.querySelectorAll(sels[i])).filter(function(e){
              return e.offsetParent!==null && !e.disabled && !e.readOnly && e.getAttribute('aria-hidden')!=='true';});
            if(a.length){return a[a.length-1];}
          }
          var ae=document.activeElement;
          if(ae&&(ae.tagName==='TEXTAREA'||ae.isContentEditable)){return ae;}
          return null;};
        """
    }

    private static func jsArray(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func jsString(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        return String(array.dropFirst().dropLast())
    }
}

/// The prompt box as an undo target: "undo that" puts back whatever it held
/// before Peeky's last write.
@MainActor
final class ChatSiteTarget: WriteUndoTarget {
    let site: ChatSiteActions.Site
    /// What Peeky last left in the box — tells a later segment whether the
    /// text there is still Peeky's own (so a correction can revise it).
    var typed: String = ""

    init(site: ChatSiteActions.Site) { self.site = site }

    var undoKey: AnyHashable { "chatsite:\(site.name)" }
    var isValid: Bool { ChatSiteActions.isOpen(site) }
    func currentValue() -> String? { ChatSiteActions.read(site) }
    func restore(_ value: String) -> BackgroundWriteResult {
        guard ChatSiteActions.write(value, into: site) else { return .verificationFailed }
        typed = value
        return .success
    }
    var frame: CGRect? { ChatSiteActions.inputFrame(site) }
}

/// Claude's part — only for corrections. Everything else is verbatim.
@MainActor
enum ChatSiteDrafter {
    private static let system = """
    You edit a prompt that someone is dictating by voice into an AI chat box \
    (ChatGPT, Gemini, Google AI Studio, Claude…). You get the current text of \
    the box and something they just said ABOUT it — a correction or change: \
    "actually make that Python, not JavaScript", "take out the last \
    sentence", "shorter", "also ask it to include tests", "I meant Tuesday". \
    Apply exactly that change and return the whole revised prompt.

    Keep their wording and voice everywhere else. Do not answer the prompt, \
    do not improve it beyond what they asked, never paste their instruction \
    or apology into it. Speech-to-text errors in the change itself ("pie \
    thon") should be read as what they meant. If what they said is plainly \
    more content rather than an instruction, append it as a new sentence.

    Reply with JSON only: {"text": "<the full revised prompt>"}.
    """

    static func revise(draft: String, instruction: String, claude: AnthropicService) async throws -> String {
        let payload = "Current prompt in the box:\n<draft>\n\(draft)\n</draft>\n\nWhat they just said: \"\(instruction)\""
        let json = try await claude.requestJSON(system: system, userText: payload, maxTokens: 2_000, timeout: 45, effort: "low")
        guard let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicService.ServiceError.emptyAnswer
        }
        return text
    }
}
