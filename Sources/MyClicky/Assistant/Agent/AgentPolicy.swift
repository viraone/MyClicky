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
    /// Serious actions that are worth a confirmation when a short label starts
    /// with them. Matching is whole-word, so "Posts" is not "post" and
    /// "Buyer's guide" is not "buy".
    private static let riskyPrefixes: [String] = [
        "buy", "purchase", "pay", "checkout", "check out", "place order",
        "order now", "complete order", "complete purchase", "donate",
        "transfer", "withdraw", "send money", "send", "post", "publish",
        "share", "tweet", "submit", "subscribe", "delete", "remove",
        "deactivate", "close account", "cancel subscription", "block",
        "unsubscribe", "confirm", "yes delete", "yes remove",
    ]

    /// A short human reason the user must confirm before the action, or nil
    /// when the action looks harmless. `action` is the tool name; for a key
    /// press it may contain the key name, e.g. "press_key Enter".
    ///
    /// Clicks are judged only by the element's own label. Enter is judged by
    /// the form's submit button label, or by the focused non-editable
    /// element's label. Being a submit button does not trigger anything.
    static func riskReason(action: String, element: ElementInfo?) -> String? {
        guard let element = element, element.found else { return nil }
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pressesEnter = normalized == "enter"
            || normalized == "press_key"
            || normalized == "browser_press_key"
            || (normalized.contains("press") && normalized.contains("enter"))

        if pressesEnter {
            if let phrase = riskyPrefix(in: element.formSubmitText) {
                return reason(for: phrase)
            }
            // Enter also activates a focused link or button. Text fields are
            // skipped here because their "text" is what the user typed.
            if !element.editable, let phrase = riskyPrefix(in: element.text) {
                return reason(for: phrase)
            }
            return nil
        }

        if normalized == "click" || normalized == "real_click" {
            if let phrase = riskyPrefix(in: element.text) {
                return reason(for: phrase)
            }
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

    /// Lowercases the label, turns punctuation and symbols into spaces, and
    /// collapses runs of whitespace, so "Check-out!" becomes "check out" and
    /// "  BUY   NOW " becomes "buy now".
    private static func normalizedLabel(_ text: String) -> String {
        let separated = text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined(separator: " ")
        return separated.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The serious phrase a label starts with, or nil when the label is empty,
    /// longer than five words, or does not begin with one of the phrases.
    private static func riskyPrefix(in text: String) -> String? {
        let label = normalizedLabel(text)
        guard !label.isEmpty, label.split(separator: " ").count <= 5 else { return nil }
        // Longer phrases first, so "send money" wins over "send".
        for phrase in riskyPrefixes.sorted(by: { $0.count > $1.count }) {
            if label == phrase || label.hasPrefix(phrase + " ") {
                return phrase
            }
        }
        return nil
    }

    private static func reason(for phrase: String) -> String {
        switch phrase {
        case "buy", "purchase", "pay", "checkout", "check out", "place order",
             "order now", "complete order", "complete purchase", "donate",
             "transfer", "withdraw", "send money":
            return "This looks like a purchase"
        case "post", "publish", "share", "tweet":
            return "This looks like it will post"
        case "delete", "remove", "deactivate", "close account", "cancel subscription",
             "block", "unsubscribe", "yes delete", "yes remove":
            return "This looks like it will delete something"
        case "send", "submit", "subscribe":
            return "This looks like it will send"
        default:
            return "This needs a confirmation"
        }
    }
}
