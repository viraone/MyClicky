import AppKit
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "actionplanner")

/// Turns a spoken request ("reply to Mom, tell her I'll be late") into a
/// short plan expressed only in `AppDriver`/`AXActions` verbs, then executes
/// it step by step. This is what lets Clicky work in any app instead of the
/// three hand-scripted ones.
enum ActionPlanner {

    struct Step: Decodable {
        var verb: String
        var app: String?
        var label: String?
        var text: String?
        var key: String?
        var modifiers: [String]?
        var direction: String?
        var irreversible: Bool?
        var note: String?
    }

    struct Plan: Decodable {
        var steps: [Step]
    }

    /// Progress and confirmation hooks the caller wires up (Mac toast +
    /// ConfirmActionPanel, and/or the phone's STATUS/CONFIRM stream).
    struct Callbacks {
        var status: (String) -> Void = { _ in }
        /// Ask the user to confirm before an irreversible step; true = proceed.
        var confirm: (String) async -> Bool = { _ in false }
    }

    private static let allowedVerbs: Set<String> = ["open", "click", "focus", "type", "press", "scroll", "done"]

    /// Backstops the model's own "irreversible" flag: these words in a
    /// click/press target force a confirmation even if it didn't say so.
    private static let irreversibleKeywords = [
        "send", "delete", "remove", "trash", "pay", "purchase", "buy",
        "submit", "confirm", "order", "checkout", "discard", "unsubscribe",
    ]

    private static let systemPrompt = """
    You control a Mac on behalf of a person who can't easily use a mouse or \
    keyboard. Given their spoken request and a list of the interactive \
    elements currently visible on screen (role, label, value), return a short \
    JSON plan that accomplishes the request using ONLY these verbs:

    - open: bring an app to the front, by its display name. {"verb":"open","app":"Mail"}
    - click: click a visible control by its label. {"verb":"click","label":"Reply"}
    - focus: click into a text field by its label. {"verb":"focus","label":"To"}
    - type: type text into whatever is currently focused. {"verb":"type","text":"..."}
    - press: press one key, optionally with modifiers. {"verb":"press","key":"return","modifiers":["cmd"]}
    - scroll: scroll the frontmost window up/down/left/right. {"verb":"scroll","direction":"down"}
    - done: nothing more is needed. Also use this — as the ONLY step — when \
      the request isn't something you can act on with these verbs (general \
      chit-chat, a question with nothing to click/type/open, or nothing on \
      screen relates to it). Give it a "note" explaining why in plain \
      language, e.g. "That's not something I can click or type — try telling \
      me what to open, click, or say."

    Rules:
    - Use a "label" exactly as it appears in the visible elements list when \
      possible; a short standard name (e.g. "Send", "Reply") is fine if the \
      element isn't listed but you're confident it exists.
    - If you were given a screenshot (because the elements list was thin, or \
      missing the control you need — icon-only toolbar buttons often have no \
      accessible label at all), you may still issue a click/focus step by \
      plainly describing what you see, e.g. "the + button in the top-left \
      toolbar" or "the blue circular button with a plus sign" — it will be \
      located on screen from that description.
    - Prefer a standard macOS keyboard shortcut over guessing at a button \
      whenever one reliably does the job in ordinary Mac apps — e.g. \
      Cmd+N (new item/event/message), Cmd+F (find), Cmd+, (preferences). \
      Issue it as {"verb":"press","key":"n","modifiers":["cmd"]}. This is \
      often more reliable than clicking an unlabeled icon.
    - Many quick-creation fields (e.g. Calendar's New Event field after \
      Cmd+N) parse a whole natural-language description at once — type the \
      full thing including any date/time as ONE "type" step (e.g. "call \
      Bank of America at 3pm today") and press return, rather than tabbing \
      between separate fields you're only guessing exist.
    - A shortcut or click that reveals a new field (a popover, a quick-entry \
      box, a dialog) does NOT necessarily put keyboard focus inside it — \
      never "type" right after such a step. Always "focus" the field first \
      (by its placeholder text if that's all it shows, e.g. a field showing \
      placeholder "Movie at 7pm on Friday" — focus with that exact text), \
      THEN type into it.
    - Only decline with "done" if you genuinely can't find anything \
      resembling what's needed and no standard shortcut applies, even after \
      seeing the screenshot.
    - Never invent a verb outside this list, and never combine two actions in \
      one step.
    - Set "irreversible": true on any step that sends, deletes, pays, submits, \
      or otherwise can't be trivially undone — the user will be asked to \
      confirm before it runs.
    - Give every step a short "note" in progress tense for a status line \
      (e.g. "Opening Mail…", "Typing your reply…", "Sending — confirm?").
    - Keep the plan minimal: only the steps this one request needs.

    Respond with ONLY a JSON object of this exact shape, no markdown fences, \
    no extra text: {"steps": [ {"verb": "...", ...}, ... ]}
    """

    /// Plans and executes `utterance` on `targetApp` (the frontmost app if
    /// nil). Callers that show their own UI before calling this should pass
    /// the app that was frontmost *before* that — otherwise, if that UI ends
    /// up frontmost itself, the plan would read and act on it instead of the
    /// app the user actually meant. `screenshot` is used only when the AX
    /// tree is thin (a canvas-drawn app) to ground the plan, and again if a
    /// click/focus target can't be found by label.
    @MainActor
    static func run(utterance: String, apiKey: String, targetApp: NSRunningApplication? = nil, screen: NSScreen,
                    callbacks: Callbacks, screenshot: @escaping () async throws -> Data) async {
        let claude = AnthropicService(apiKey: apiKey)
        var app = targetApp ?? NSWorkspace.shared.frontmostApplication
        let elements = AXActions.read(in: app)

        var plan: Plan
        do {
            plan = try await requestPlan(utterance: utterance, elements: elements, claude: claude,
                                         includeScreenshot: elements.isEmpty, screenshot: screenshot)
        } catch {
            log.error("plan request failed: \(error.localizedDescription, privacy: .public)")
            callbacks.status("Couldn't work out how to do that — \(error.localizedDescription)")
            return
        }
        guard !plan.steps.isEmpty, plan.steps.allSatisfy({ allowedVerbs.contains($0.verb) }) else {
            log.notice("refused plan with unsupported verb(s)")
            callbacks.status("That would need an action I don't support yet — stopped for safety.")
            return
        }

        // AX found *some* elements but none worth acting on (e.g. an
        // icon-only toolbar button with no usable label) — give Claude one
        // more chance with an actual screenshot before giving up.
        if isDeclined(plan), !elements.isEmpty {
            log.notice("AX-only plan declined — retrying with a screenshot for visual grounding")
            do {
                let retryPlan = try await requestPlan(utterance: utterance, elements: elements, claude: claude,
                                                       includeScreenshot: true, screenshot: screenshot)
                if isDeclined(retryPlan) {
                    log.notice("screenshot retry also declined: \(retryPlan.steps.first?.note ?? "(no note)", privacy: .public)")
                } else {
                    log.notice("screenshot retry produced \(retryPlan.steps.count) step(s)")
                }
                // Use the retry's plan either way — even a second decline is
                // more informative (it saw the actual screen) than the stale
                // pre-screenshot note, which can misleadingly say things like
                // "without a screenshot" right after one was in fact tried.
                if !retryPlan.steps.isEmpty, retryPlan.steps.allSatisfy({ allowedVerbs.contains($0.verb) }) {
                    plan = retryPlan
                }
            } catch {
                log.error("screenshot retry failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        var executedAny = false
        for step in plan.steps {
            if step.verb == "done" {
                // "done" with nothing executed before it means Claude decided
                // there was nothing here it could act on — say so instead of
                // the misleading generic "Done." (nothing was, in fact, done).
                let fallback = executedAny ? "Done." : "That's not something I can do — try telling me what to click, type, or open."
                callbacks.status(step.note ?? fallback)
                return
            }
            callbacks.status(step.note ?? describe(step))
            if isIrreversible(step) {
                log.notice("gating irreversible step: \(step.verb, privacy: .public) \(step.label ?? step.key ?? "", privacy: .public)")
                guard await callbacks.confirm(step.note ?? describe(step)) else {
                    log.notice("irreversible step declined by user")
                    callbacks.status("Cancelled — nothing more was done.")
                    return
                }
                log.notice("irreversible step confirmed by user")
                // Confirming just clicked a button on a DIFFERENT panel,
                // which steals keyboard focus away from the target app — a
                // "press"/"type" step fires a raw keyboard event to whatever
                // currently has focus, so without this it can silently land
                // on the wrong window instead of the app being controlled.
                app?.activate(options: [.activateAllWindows])
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard await execute(step, app: &app, screen: screen, screenshot: screenshot, claude: claude) else {
                log.notice("step failed, stopping: \(step.verb, privacy: .public)")
                callbacks.status("Got stuck on: \(step.note ?? describe(step))")
                return
            }
            executedAny = true
            log.debug("post-step elements: \(AXActions.read(in: app).count)")
        }
        callbacks.status("Done.")
    }

    private static func isIrreversible(_ step: Step) -> Bool {
        if step.irreversible == true { return true }
        let haystack = [step.label, step.key].compactMap { $0 }.joined(separator: " ").lowercased()
        return irreversibleKeywords.contains { haystack.contains($0) }
    }

    private static func describe(_ step: Step) -> String {
        switch step.verb {
        case "open": "Opening \(step.app ?? "the app")…"
        case "click": "Clicking \(step.label ?? "")…"
        case "focus": "Selecting \(step.label ?? "a field")…"
        case "type": "Typing…"
        case "press": "Pressing \(step.key ?? "a key")…"
        case "scroll": "Scrolling…"
        default: "Working…"
        }
    }

    @MainActor
    private static func execute(_ step: Step, app: inout NSRunningApplication?, screen: NSScreen,
                                screenshot: @escaping () async throws -> Data, claude: AnthropicService) async -> Bool {
        // Never log step.text verbatim — it's the actual message/content
        // being typed, which can be personal; log its length instead.
        var target = step.app ?? step.label ?? step.key ?? step.direction
            ?? step.text.map { "(\($0.count) chars)" } ?? ""
        if step.verb == "press", let modifiers = step.modifiers, !modifiers.isEmpty {
            target = modifiers.joined(separator: "+") + "+" + target
        }
        log.notice("executing: \(step.verb, privacy: .public) \(target, privacy: .public)")
        switch step.verb {
        case "open":
            guard let name = step.app, let resolved = AppDriver.ensureRunning(appNamed: name) else { return false }
            AppDriver.bringForward(resolved)
            app = resolved
            try? await Task.sleep(nanoseconds: 400_000_000)
            return true
        case "click":
            guard let label = step.label else { return false }
            if AXActions.click(label: label, in: app) {
                usleep(300_000)
                return true
            }
            return await visionClickRetrying(describing: label, screen: screen, screenshot: screenshot, claude: claude)
        case "focus":
            guard let label = step.label else { return false }
            if AXActions.focus(label: label, in: app) {
                usleep(250_000)
                return true
            }
            return await visionClickRetrying(describing: label, screen: screen, screenshot: screenshot, claude: claude)
        case "type":
            guard let text = step.text else { return false }
            if AXActions.type(text, in: app) {
                usleep(250_000)
                return true
            }
            // AX couldn't find (or verify focus landed on) an editable
            // target — some fields (e.g. Calendar's "Create Quick Event"
            // popover) live entirely outside the normal AX window tree and
            // can never be found by traversal. Locate the empty field
            // visually instead, click it, then retry the same paste.
            let fieldDescription = "the empty text input field that's ready for typing right now, such as a just-opened quick-entry popover or dialog field"
            guard await visionClickRetrying(describing: fieldDescription, screen: screen, screenshot: screenshot, claude: claude) else { return false }
            guard AXActions.type(text, in: app) else { return false }
            usleep(250_000)
            return true
        case "press":
            guard let key = step.key else { return false }
            AXActions.press(key, modifiers: Set(step.modifiers ?? []))
            // A modified press (Cmd+N, etc.) often triggers app-level UI —
            // a new window/popover that needs time to appear and take
            // keyboard focus before the next step can reliably act on it.
            // click/focus already wait after acting; press/type never did.
            usleep(step.modifiers?.isEmpty == false ? 500_000 : 200_000)
            return true
        case "scroll":
            guard let direction = step.direction.flatMap(AXActions.ScrollDirection.init(rawValue:)) else { return false }
            AXActions.scroll(direction)
            return true
        default:
            return false
        }
    }

    /// Tries `visionClick` up to twice — a single vision call can miss even
    /// when the target is clearly visible (observed live: the identical
    /// description succeeded once, then failed with no bounding box twice in
    /// a row) — worth one retry given each attempt costs a Claude round-trip
    /// and the user is speaking, not typing.
    @MainActor
    private static func visionClickRetrying(describing label: String, screen: NSScreen, screenshot: @escaping () async throws -> Data,
                                            claude: AnthropicService) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { log.notice("vision fallback: retrying \(label, privacy: .public)") }
            if await visionClick(describing: label, screen: screen, screenshot: screenshot, claude: claude) { return true }
        }
        return false
    }

    /// AX couldn't find the target by label — fall back to Claude vision
    /// locating it on screen, the same path "click the save button" already
    /// uses, and click the returned bounding box. `screen` MUST be the same
    /// screen `screenshot` was captured from — mapping Claude's normalized
    /// coordinates against a different screen's frame (e.g. independently
    /// querying NSScreen.main on a multi-monitor setup) silently produces a
    /// click at a nonsensical location on whatever screen that happens to be.
    @MainActor
    private static func visionClick(describing label: String, screen: NSScreen, screenshot: @escaping () async throws -> Data,
                                    claude: AnthropicService) async -> Bool {
        log.notice("vision fallback: locating \(label, privacy: .public)")
        do {
            let image = try await screenshot()
            let dumpPath = "/tmp/myclicky-vision-\(Int(Date().timeIntervalSince1970)).jpg"
            try? image.write(to: URL(fileURLWithPath: dumpPath))
            log.notice("vision fallback: saved screenshot to \(dumpPath, privacy: .public)")
            let question = "Locate the on-screen element labeled or described as \u{201c}\(label)\u{201d} and return its bounding box."
            let answer = try await claude.ask(question: question, jpegImage: image)
            guard let box = answer.highlight else {
                log.notice("vision fallback: no bounding box returned for \(label, privacy: .public)")
                return false
            }
            let rect = screenRect(fromNormalized: box, on: screen)
            log.notice("vision fallback: clicking (\(Int(rect.midX)), \(Int(rect.midY))) for \(label, privacy: .public)")
            MouseClicker.click(at: NSPoint(x: rect.midX, y: rect.midY))
            return true
        } catch {
            log.notice("vision fallback failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func screenRect(fromNormalized box: CGRect, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + (1.0 - box.maxY) * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
    }

    private static func requestPlan(utterance: String, elements: [AXElement], claude: AnthropicService,
                                    includeScreenshot: Bool, screenshot: @escaping () async throws -> Data) async throws -> Plan {
        let lines = elements.prefix(150).map { element -> String in
            var line = "\(element.role) \"\(element.label)\""
            if !element.value.isEmpty { line += " value=\"\(element.value)\"" }
            if !element.enabled { line += " (disabled)" }
            return line
        }
        let userText = """
        User said: \u{201c}\(utterance)\u{201d}

        Visible interactive elements:
        \(lines.isEmpty ? "(none found)" : lines.joined(separator: "\n"))
        """

        let jpegImage = includeScreenshot ? try? await screenshot() : nil

        let json = try await claude.requestJSON(system: systemPrompt, userText: userText, jpegImage: jpegImage)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    /// True for a plan that's just a single declined "done" — Claude found
    /// nothing here to act on.
    private static func isDeclined(_ plan: Plan) -> Bool {
        plan.steps.count == 1 && plan.steps[0].verb == "done"
    }
}
