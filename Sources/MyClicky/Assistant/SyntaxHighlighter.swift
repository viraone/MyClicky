import AppKit

/// Syntax colouring for the Peeky Code preview, in VS Code's default
/// "Dark Modern" palette so a file looks the same here as on screen 2.
/// Regex-based, one pass per language — enough for the highlighting a
/// reader relies on (comments, strings, keywords, names), not a parser.
enum SyntaxHighlighter {
    // Dark Modern token colours.
    static let plain      = NSColor(srgbRed: 0xCC/255, green: 0xCC/255, blue: 0xCC/255, alpha: 1)
    static let comment    = NSColor(srgbRed: 0x6A/255, green: 0x99/255, blue: 0x55/255, alpha: 1)
    static let string     = NSColor(srgbRed: 0xCE/255, green: 0x91/255, blue: 0x78/255, alpha: 1)
    static let number     = NSColor(srgbRed: 0xB5/255, green: 0xCE/255, blue: 0xA8/255, alpha: 1)
    static let keyword    = NSColor(srgbRed: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1)
    static let control    = NSColor(srgbRed: 0xC5/255, green: 0x86/255, blue: 0xC0/255, alpha: 1)
    static let function   = NSColor(srgbRed: 0xDC/255, green: 0xDC/255, blue: 0xAA/255, alpha: 1)
    static let type       = NSColor(srgbRed: 0x4E/255, green: 0xC9/255, blue: 0xB0/255, alpha: 1)
    static let variable   = NSColor(srgbRed: 0x9C/255, green: 0xDC/255, blue: 0xFE/255, alpha: 1)
    static let tag        = keyword
    static let attribute  = variable
    static let selector   = NSColor(srgbRed: 0xD7/255, green: 0xBA/255, blue: 0x7D/255, alpha: 1)
    static let punctuation = NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1)
    static let background = NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)

    enum Language { case javascript, swift, python, css, html, json, shell, markdown, other }

    static func language(for path: String) -> Language {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "c", "cpp", "h", "m", "go", "rs", "cs": return .javascript
        case "swift": return .swift
        case "py", "rb": return .python
        case "css", "scss", "less": return .css
        case "html", "htm", "xml", "svg", "vue", "svelte": return .html
        case "json", "jsonc", "yml", "yaml", "toml", "plist": return .json
        case "sh", "zsh", "bash", "fish": return .shell
        case "md", "markdown": return .markdown
        default: return .other
        }
    }

    /// One rule: a pattern and the colour for its match (or for one capture group).
    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        let group: Int
        init(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) {
            regex = try! NSRegularExpression(pattern: pattern, options: options.union(.anchorsMatchLines))
            self.color = color
            self.group = group
        }
    }

    private static let cLikeKeywords = #"\b(?:var|let|const|function|class|extends|new|this|super|return|import|export|from|default|async|await|static|get|set|typeof|instanceof|void|delete|in|of|true|false|null|undefined|NaN|public|private|protected|interface|enum|implements|package|final|abstract|int|float|double|boolean|char|long|short|byte|struct|fn|pub|mut|impl|trait|use|mod|func|type|chan|go|defer|map|range)\b"#
    private static let cLikeControl = #"\b(?:if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|throws|yield|with|match|loop|select|fallthrough)\b"#

    // Rules are applied in order; later rules win, so comments and strings go last.
    private static let rules: [Language: [Rule]] = [
        .javascript: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, type),
            Rule(#"\b([A-Za-z_$][\w$]*)\s*(?=\()"#, function, group: 1),
            Rule(cLikeKeywords, keyword),
            Rule(cLikeControl, control),
            Rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, string),
            Rule(#"//.*$"#, comment),
            Rule(#"/\*[\s\S]*?\*/"#, comment),
        ],
        .swift: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, type),
            Rule(#"\b([a-z_][\w]*)\s*(?=\()"#, function, group: 1),
            Rule(#"\b(?:let|var|func|class|struct|enum|protocol|extension|import|init|deinit|self|Self|super|static|final|private|fileprivate|public|internal|open|override|mutating|inout|some|any|where|as|is|true|false|nil|typealias|associatedtype|lazy|weak|unowned|async|await|actor|nonisolated|throws|rethrows|try|indirect|convenience|required|subscript|operator|precedencegroup|willSet|didSet|get|set)\b"#, keyword),
            Rule(#"\b(?:if|else|guard|for|in|while|repeat|switch|case|default|break|continue|return|throw|defer|do|catch|fallthrough)\b"#, control),
            Rule(#"@\w+|#\w+"#, control),
            Rule(#""(?:[^"\\\n]|\\.)*"|"""[\s\S]*?""""#, string),
            Rule(#"//.*$"#, comment),
            Rule(#"/\*[\s\S]*?\*/"#, comment),
        ],
        .python: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, type),
            Rule(#"\b([A-Za-z_]\w*)\s*(?=\()"#, function, group: 1),
            Rule(#"\b(?:def|class|lambda|import|from|as|global|nonlocal|self|True|False|None|and|or|not|is|in|async|await|del|assert|with|yield|end|module|require|attr_accessor|puts|nil|then)\b"#, keyword),
            Rule(#"\b(?:if|elif|else|for|while|try|except|finally|raise|return|break|continue|pass|unless|until|do|begin|rescue|ensure|case|when)\b"#, control),
            Rule(#"@\w+"#, control),
            Rule(#""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, string),
            Rule(#"#.*$"#, comment),
        ],
        .css: [
            Rule(#"^[^{}\n/][^{}\n]*(?=\{)"#, selector),
            Rule(#"([A-Za-z-]+)\s*(?=:)"#, variable, group: 1),
            Rule(#"(?<=:)[^;{}\n]+"#, string),
            Rule(#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, number),
            Rule(#"#[0-9A-Fa-f]{3,8}\b"#, number),
            Rule(#"@[\w-]+"#, control),
            Rule(#"![\w-]+"#, control),
            Rule(#"/\*[\s\S]*?\*/"#, comment),
        ],
        .html: [
            Rule(#"<!DOCTYPE[^>]*>"#, comment, options: .caseInsensitive),
            Rule(#"</?\s*([A-Za-z][\w:-]*)"#, tag, group: 1),
            Rule(#"</?|/?>"#, punctuation),
            Rule(#"\s([A-Za-z_:][\w:.-]*)(?==)"#, attribute, group: 1),
            Rule(#"=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#, string, group: 1),
            Rule(#"&\w+;"#, control),
            Rule(#"<!--[\s\S]*?-->"#, comment),
        ],
        .json: [
            Rule(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, number),
            Rule(#"\b(?:true|false|null|yes|no)\b"#, keyword),
            Rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, string),
            Rule(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, variable),
            Rule(#"^\s*([\w.-]+)(?=\s*:)"#, variable, group: 1),
            Rule(#"(?:^|\s)#.*$|//.*$"#, comment),
        ],
        .shell: [
            Rule(#"\b\d+\b"#, number),
            Rule(#"\$\{?[\w@#?*-]+\}?"#, variable),
            Rule(#"\b(?:if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|exit|local|export|source|alias|set|unset|readonly|shift|break|continue)\b"#, control),
            Rule(#"(?<=\s|^)-{1,2}[\w-]+"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*"|'[^']*'"#, string),
            Rule(#"#.*$"#, comment),
        ],
        .markdown: [
            Rule(#"^#{1,6} .*$"#, keyword),
            Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, function),
            Rule(#"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#, type),
            Rule(#"`[^`\n]+`"#, string),
            Rule(#"^```[\s\S]*?^```"#, string),
            Rule(#"\[[^\]\n]+\]\([^)\n]+\)"#, variable),
            Rule(#"^\s*[-*+] |^\s*\d+\. "#, control),
            Rule(#"^>.*$"#, comment),
        ],
    ]

    /// Paints `storage` in place: full range reset to `plain`, then each
    /// rule's matches in its colour.
    static func highlight(_ storage: NSTextStorage, language: Language, font: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: plain], range: full)
        if let rules = rules[language] {
            let text = storage.string
            for rule in rules {
                rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                    guard let match else { return }
                    let range = match.range(at: rule.group)
                    guard range.location != NSNotFound, range.length > 0 else { return }
                    storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                }
            }
        }
        storage.endEditing()
    }
}
