import Foundation

/// What the page's `describe` script says about one element. The fields
/// mirror the JSON that `BrowserAgentScripts.describe(id:)` and
/// `describeActive()` answer.
struct ElementInfo: Equatable {
    var found: Bool
    var tag: String
    var type: String
    var text: String
    var href: String
    var sensitive: Bool
    var isSubmit: Bool
    var formSubmitText: String
    var editable: Bool

    init(found: Bool = true,
         tag: String = "",
         type: String = "",
         text: String = "",
         href: String = "",
         sensitive: Bool = false,
         isSubmit: Bool = false,
         formSubmitText: String = "",
         editable: Bool = false) {
        self.found = found
        self.tag = tag
        self.type = type
        self.text = text
        self.href = href
        self.sensitive = sensitive
        self.isSubmit = isSubmit
        self.formSubmitText = formSubmitText
        self.editable = editable
    }

    /// Parses the `describe` JSON. Answers nil when the page reported an
    /// error instead of an element.
    init?(json: [String: Any]) {
        if let error = json["error"] as? String, !error.isEmpty { return nil }
        found = Self.bool(json["found"], defaultValue: true)
        tag = Self.string(json["tag"])
        type = Self.string(json["type"])
        text = Self.string(json["text"])
        href = Self.string(json["href"])
        sensitive = Self.bool(json["sensitive"], defaultValue: false)
        isSubmit = Self.bool(json["isSubmit"], defaultValue: false)
        formSubmitText = Self.string(json["formSubmitText"])
        editable = Self.bool(json["editable"], defaultValue: false)
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return defaultValue
    }
}

/// Pure decisions the browser agent makes before it touches the user's page:
/// which actions need a confirmation, which fields must not be typed into,
/// and which URLs may be opened.
struct AgentPolicy {
    /// Words and phrases that make an action worth a confirmation. Matching is
    /// case-insensitive and whole-word, so "Buyer's guide" is not a purchase
    /// and "Save draft" is not "Save and continue".
    private static let riskyPhrases: [String] = [
        "buy", "purchase", "pay", "checkout", "place order", "order now",
        "subscribe", "donate", "send", "submit", "post", "publish",
        "delete", "remove", "confirm", "transfer", "withdraw",
        "sign out", "log out", "unsubscribe", "apply", "book", "reserve",
        "accept", "agree", "authorize", "allow", "save and continue", "complete",
    ]

    /// A short human reason the user must confirm before the action, or nil
    /// when the action looks harmless. `action` is the tool name; for a key
    /// press it may contain the key name, e.g. "press_key Enter".
    static func riskReason(action: String, element: ElementInfo?) -> String? {
        guard let element = element, element.found else { return nil }
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pressesEnter = normalized == "enter"
            || normalized == "press_key"
            || normalized == "browser_press_key"
            || (normalized.contains("press") && normalized.contains("enter"))

        if pressesEnter {
            if element.isSubmit || !element.formSubmitText.isEmpty {
                if let phrase = riskyPhrase(in: element.formSubmitText) {
                    return reason(for: phrase)
                }
                return "Pressing Enter may submit this form"
            }
            // Enter also activates a focused link or button. Text fields are
            // skipped here because their "text" is what the user typed.
            if !element.editable, let phrase = riskyPhrase(in: element.text) {
                return reason(for: phrase)
            }
            return nil
        }

        if let phrase = riskyPhrase(in: element.text) {
            return reason(for: phrase)
        }
        if element.isSubmit {
            if let phrase = riskyPhrase(in: element.formSubmitText) {
                return reason(for: phrase)
            }
            return "This button submits a form"
        }
        return nil
    }

    /// What to tell the model when it tries to type into a password, payment
    /// card or ID field. The user fills those in themselves.
    static func sensitiveTypingRefusal(element: ElementInfo? = nil) -> String {
        let label = element?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = label.isEmpty ? "That field" : "\"\(label)\""
        return "\(subject) looks like a password, payment card or ID field. I won't type in it. Ask the user to fill that in themselves."
    }

    /// Only http and https URLs may be opened. A bare address such as
    /// "example.com" gets https://. Everything else — javascript:, file:,
    /// data:, chrome: — is refused.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let colon = trimmed.firstIndex(of: ":") {
            let head = String(trimmed[..<colon])
            let tail = String(trimmed[trimmed.index(after: colon)...])
            if !head.contains("/") && !head.contains("?") && !head.contains("#") {
                let scheme = head.lowercased()
                if scheme == "http" || scheme == "https" {
                    return accepted(trimmed)
                }
                // "example.com:8080" is a host and port, not a scheme.
                if tail.first?.isNumber == true, head.contains(".") || head.lowercased() == "localhost" {
                    return accepted("https://" + trimmed)
                }
                return nil
            }
        }
        return accepted("https://" + trimmed)
    }

    private static func accepted(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    private static func riskyPhrase(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        for phrase in riskyPhrases {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return phrase
            }
        }
        return nil
    }

    private static func reason(for phrase: String) -> String {
        "This looks like it will \(humanAction(for: phrase))"
    }

    private static func humanAction(for phrase: String) -> String {
        switch phrase {
        case "buy": return "buy something"
        case "purchase": return "make a purchase"
        case "pay": return "take a payment"
        case "checkout": return "start checkout"
        case "place order", "order now": return "place an order"
        case "subscribe": return "subscribe"
        case "donate": return "donate"
        case "send": return "send something"
        case "submit": return "submit a form"
        case "post": return "post something"
        case "publish": return "publish something"
        case "delete": return "delete something"
        case "remove": return "remove something"
        case "confirm": return "confirm something"
        case "transfer", "withdraw": return "move money"
        case "sign out", "log out": return "sign you out"
        case "unsubscribe": return "unsubscribe"
        case "apply": return "apply"
        case "book", "reserve": return "book or reserve something"
        case "accept", "agree": return "accept something"
        case "authorize", "allow": return "grant permission"
        case "save and continue": return "save and continue"
        case "complete": return "complete an action"
        default: return phrase
        }
    }
}
