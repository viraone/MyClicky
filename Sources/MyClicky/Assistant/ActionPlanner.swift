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
    static func run(utterance: String, apiKey: String, targetApp: NSRunningApplication? = nil,
                    callbacks: Callbacks, screenshot: @escaping () async throws -> Data) async {
        let claude = AnthropicService(apiKey: apiKey)
        var app = targetApp ?? NSWorkspace.shared.frontmostApplication
        let elements = AXActions.read(in: app)

        let plan: Plan
        do {
            plan = try await requestPlan(utterance: utterance, elements: elements, claude: claude, screenshot: screenshot)
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
            }
            guard await execute(step, app: &app, screenshot: screenshot, claude: claude) else {
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
    private static func execute(_ step: Step, app: inout NSRunningApplication?,
                                screenshot: @escaping () async throws -> Data, claude: AnthropicService) async -> Bool {
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
            return await visionClick(describing: label, screenshot: screenshot, claude: claude)
        case "focus":
            guard let label = step.label else { return false }
            if AXActions.focus(label: label, in: app) {
                usleep(250_000)
                return true
            }
            return await visionClick(describing: label, screenshot: screenshot, claude: claude)
        case "type":
            guard let text = step.text else { return false }
            AXActions.type(text)
            return true
        case "press":
            guard let key = step.key else { return false }
            AXActions.press(key, modifiers: Set(step.modifiers ?? []))
            return true
        case "scroll":
            guard let direction = step.direction.flatMap(AXActions.ScrollDirection.init(rawValue:)) else { return false }
            AXActions.scroll(direction)
            return true
        default:
            return false
        }
    }

    /// AX couldn't find the target by label — fall back to Claude vision
    /// locating it on screen, the same path "click the save button" already
    /// uses, and click the returned bounding box.
    @MainActor
    private static func visionClick(describing label: String, screenshot: @escaping () async throws -> Data,
                                    claude: AnthropicService) async -> Bool {
        guard let screen = NSScreen.main else { return false }
        do {
            let image = try await screenshot()
            let question = "Locate the on-screen element labeled or described as \u{201c}\(label)\u{201d} and return its bounding box."
            let answer = try await claude.ask(question: question, jpegImage: image)
            guard let box = answer.highlight else { return false }
            let rect = screenRect(fromNormalized: box, on: screen)
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
                                    screenshot: @escaping () async throws -> Data) async throws -> Plan {
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

        // AX came back thin (a canvas-drawn app, or nothing frontmost yet) —
        // ground the plan with a screenshot instead.
        let jpegImage = elements.isEmpty ? try? await screenshot() : nil

        let json = try await claude.requestJSON(system: systemPrompt, userText: userText, jpegImage: jpegImage)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Plan.self, from: data)
    }
}
