import AppKit

/// Syntax colouring for the Peeky Code preview. Ships with VS Code's default
/// "Dark Modern" palette so a file looks the same here as on screen 2, and
/// takes themes and grammars from extensions on top of that.
/// Regex-based, one pass per language — enough for the highlighting a
/// reader relies on (comments, strings, keywords, names), not a parser.
enum SyntaxHighlighter {
    /// The kinds of thing a rule can colour. Theme files key on these names.
    enum Token: String, CaseIterable, Sendable {
        case plain, comment, string, number, keyword, control, function, type, variable,
             tag, attribute, selector, punctuation
    }

    struct Theme: Equatable, Sendable {
        let id: String
        let name: String
        var colors: [Token: NSColor]
        var background: NSColor

        func color(_ token: Token) -> NSColor { colors[token] ?? Theme.darkModern.colors[token] ?? Theme.darkModern.plain }
        var plain: NSColor { color(.plain) }

        static let darkModern = Theme(
            id: "dark-modern", name: "Dark Modern",
            colors: [
                .plain:       NSColor(srgbRed: 0xCC/255, green: 0xCC/255, blue: 0xCC/255, alpha: 1),
                .comment:     NSColor(srgbRed: 0x6A/255, green: 0x99/255, blue: 0x55/255, alpha: 1),
                .string:      NSColor(srgbRed: 0xCE/255, green: 0x91/255, blue: 0x78/255, alpha: 1),
                .number:      NSColor(srgbRed: 0xB5/255, green: 0xCE/255, blue: 0xA8/255, alpha: 1),
                .keyword:     NSColor(srgbRed: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1),
                .control:     NSColor(srgbRed: 0xC5/255, green: 0x86/255, blue: 0xC0/255, alpha: 1),
                .function:    NSColor(srgbRed: 0xDC/255, green: 0xDC/255, blue: 0xAA/255, alpha: 1),
                .type:        NSColor(srgbRed: 0x4E/255, green: 0xC9/255, blue: 0xB0/255, alpha: 1),
                .variable:    NSColor(srgbRed: 0x9C/255, green: 0xDC/255, blue: 0xFE/255, alpha: 1),
                .tag:         NSColor(srgbRed: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1),
                .attribute:   NSColor(srgbRed: 0x9C/255, green: 0xDC/255, blue: 0xFE/255, alpha: 1),
                .selector:    NSColor(srgbRed: 0xD7/255, green: 0xBA/255, blue: 0x7D/255, alpha: 1),
                .punctuation: NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1),
            ],
            background: NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1)
        )

        /// Builds a theme from an extension's `{ token: "#RRGGBB" }` map.
        /// Unknown keys are ignored; missing ones fall back to Dark Modern.
        init?(manifest: ExtensionManifest.Theme) {
            var colors: [Token: NSColor] = [:]
            var background = Theme.darkModern.background
            for (key, hex) in manifest.colors {
                guard let color = NSColor(hex: hex) else { return nil }
                if key == "background" { background = color } else if let token = Token(rawValue: key) { colors[token] = color }
            }
            self.init(id: manifest.id, name: manifest.name, colors: colors, background: background)
        }

        init(id: String, name: String, colors: [Token: NSColor], background: NSColor) {
            self.id = id; self.name = name; self.colors = colors; self.background = background
        }
    }

    /// The theme in force. Set by `ExtensionManager` when the user picks one
    /// (or its extension goes away); the editor re-paints on `themeID`.
    static var theme: Theme {
        get { lock.lock(); defer { lock.unlock() }; return _theme }
        set { lock.lock(); _theme = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _theme = Theme.darkModern

    // Kept as the names the editor already uses.
    static var plain: NSColor { theme.plain }
    static var background: NSColor { theme.background }
    static var comment: NSColor { theme.color(.comment) }
    static var keyword: NSColor { theme.color(.keyword) }
    static var string: NSColor { theme.color(.string) }
    static var function: NSColor { theme.color(.function) }
    static var number: NSColor { theme.color(.number) }

    enum Language: Hashable, Sendable {
        case javascript, swift, python, css, html, json, shell, markdown, other
        /// A grammar an extension registered, by its manifest `id`.
        case custom(String)

        static let builtins: [String: Language] = [
            "javascript": .javascript, "swift": .swift, "python": .python, "css": .css,
            "html": .html, "json": .json, "shell": .shell, "markdown": .markdown,
        ]
    }

    static func language(for path: String) -> Language {
        let ext = (path as NSString).pathExtension.lowercased()
        if let custom = ExtensionRegistry.current.language(forExtension: ext) { return .custom(custom.item.id) }
        return builtinLanguage(forExtension: ext)
    }

    static func builtinLanguage(forExtension ext: String) -> Language {
        switch ext {
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

    /// One rule: a pattern and the token for its match (or for one capture group).
    struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let token: Token
        let group: Int
        init(_ pattern: String, _ token: Token, group: Int = 0, options: NSRegularExpression.Options = []) {
            regex = try! NSRegularExpression(pattern: pattern, options: options.union(.anchorsMatchLines))
            self.token = token
            self.group = group
        }
        init?(safe pattern: String, _ token: Token, group: Int = 0, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options.union(.anchorsMatchLines)) else { return nil }
            self.regex = regex
            self.token = token
            self.group = group
        }
    }

    private static let cLikeKeywords = #"\b(?:var|let|const|function|class|extends|new|this|super|return|import|export|from|default|async|await|static|get|set|typeof|instanceof|void|delete|in|of|true|false|null|undefined|NaN|public|private|protected|interface|enum|implements|package|final|abstract|int|float|double|boolean|char|long|short|byte|struct|fn|pub|mut|impl|trait|use|mod|func|type|chan|go|defer|map|range)\b"#
    private static let cLikeControl = #"\b(?:if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|throws|yield|with|match|loop|select|fallthrough)\b"#

    // Rules are applied in order; later rules win, so comments and strings go last.
    private static let builtinRules: [Language: [Rule]] = [
        .javascript: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, .number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type),
            Rule(#"\b([A-Za-z_$][\w$]*)\s*(?=\()"#, .function, group: 1),
            Rule(cLikeKeywords, .keyword),
            Rule(cLikeControl, .control),
            Rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#, .string),
            Rule(#"//.*$"#, .comment),
            Rule(#"/\*[\s\S]*?\*/"#, .comment),
        ],
        .swift: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, .number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type),
            Rule(#"\b([a-z_][\w]*)\s*(?=\()"#, .function, group: 1),
            Rule(#"\b(?:let|var|func|class|struct|enum|protocol|extension|import|init|deinit|self|Self|super|static|final|private|fileprivate|public|internal|open|override|mutating|inout|some|any|where|as|is|true|false|nil|typealias|associatedtype|lazy|weak|unowned|async|await|actor|nonisolated|throws|rethrows|try|indirect|convenience|required|subscript|operator|precedencegroup|willSet|didSet|get|set)\b"#, .keyword),
            Rule(#"\b(?:if|else|guard|for|in|while|repeat|switch|case|default|break|continue|return|throw|defer|do|catch|fallthrough)\b"#, .control),
            Rule(#"@\w+|#\w+"#, .control),
            Rule(#""(?:[^"\\\n]|\\.)*"|"""[\s\S]*?""""#, .string),
            Rule(#"//.*$"#, .comment),
            Rule(#"/\*[\s\S]*?\*/"#, .comment),
        ],
        .python: [
            Rule(#"\b\d+(?:\.\d+)?\b"#, .number),
            Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type),
            Rule(#"\b([A-Za-z_]\w*)\s*(?=\()"#, .function, group: 1),
            Rule(#"\b(?:def|class|lambda|import|from|as|global|nonlocal|self|True|False|None|and|or|not|is|in|async|await|del|assert|with|yield|end|module|require|attr_accessor|puts|nil|then)\b"#, .keyword),
            Rule(#"\b(?:if|elif|else|for|while|try|except|finally|raise|return|break|continue|pass|unless|until|do|begin|rescue|ensure|case|when)\b"#, .control),
            Rule(#"@\w+"#, .control),
            Rule(#""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, .string),
            Rule(#"#.*$"#, .comment),
        ],
        .css: [
            Rule(#"^[^{}\n/][^{}\n]*(?=\{)"#, .selector),
            Rule(#"([A-Za-z-]+)\s*(?=:)"#, .variable, group: 1),
            Rule(#"(?<=:)[^;{}\n]+"#, .string),
            Rule(#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, .number),
            Rule(#"#[0-9A-Fa-f]{3,8}\b"#, .number),
            Rule(#"@[\w-]+"#, .control),
            Rule(#"![\w-]+"#, .control),
            Rule(#"/\*[\s\S]*?\*/"#, .comment),
        ],
        .html: [
            Rule(#"<!DOCTYPE[^>]*>"#, .comment, options: .caseInsensitive),
            Rule(#"</?\s*([A-Za-z][\w:-]*)"#, .tag, group: 1),
            Rule(#"</?|/?>"#, .punctuation),
            Rule(#"\s([A-Za-z_:][\w:.-]*)(?==)"#, .attribute, group: 1),
            Rule(#"=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#, .string, group: 1),
            Rule(#"&\w+;"#, .control),
            Rule(#"<!--[\s\S]*?-->"#, .comment),
        ],
        .json: [
            Rule(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number),
            Rule(#"\b(?:true|false|null|yes|no)\b"#, .keyword),
            Rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, .string),
            Rule(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .variable),
            Rule(#"^\s*([\w.-]+)(?=\s*:)"#, .variable, group: 1),
            Rule(#"(?:^|\s)#.*$|//.*$"#, .comment),
        ],
        .shell: [
            Rule(#"\b\d+\b"#, .number),
            Rule(#"\$\{?[\w@#?*-]+\}?"#, .variable),
            Rule(#"\b(?:if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|exit|local|export|source|alias|set|unset|readonly|shift|break|continue)\b"#, .control),
            Rule(#"(?<=\s|^)-{1,2}[\w-]+"#, .keyword),
            Rule(#""(?:[^"\\]|\\.)*"|'[^']*'"#, .string),
            Rule(#"#.*$"#, .comment),
        ],
        .markdown: [
            Rule(#"^#{1,6} .*$"#, .keyword),
            Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .function),
            Rule(#"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#, .type),
            Rule(#"`[^`\n]+`"#, .string),
            Rule(#"^```[\s\S]*?^```"#, .string),
            Rule(#"\[[^\]\n]+\]\([^)\n]+\)"#, .variable),
            Rule(#"^\s*[-*+] |^\s*\d+\. "#, .control),
            Rule(#"^>.*$"#, .comment),
        ],
    ]

    // MARK: Extension grammars

    /// Built lazily from the registry and dropped on every reload.
    nonisolated(unsafe) private static var customRules: [String: [Rule]] = [:]

    static func invalidateCustomLanguages() {
        lock.lock(); customRules = [:]; lock.unlock()
    }

    static func rules(for language: Language) -> [Rule] {
        switch language {
        case .custom(let id):
            lock.lock()
            if let cached = customRules[id] { lock.unlock(); return cached }
            lock.unlock()
            let built = ExtensionRegistry.current.languages.last { $0.item.id == id }.map { rules(from: $0.item) } ?? []
            lock.lock(); customRules[id] = built; lock.unlock()
            return built
        default:
            return builtinRules[language] ?? []
        }
    }

    /// Turns a manifest grammar into rules: the base language's rules with
    /// the extra words and comment markers inserted before the base's
    /// strings/comments, then any raw rules of its own.
    static func rules(from language: ExtensionManifest.Language) -> [Rule] {
        var rules: [Rule] = []
        let base = language.base.flatMap { Language.builtins[$0] }
        if let base { rules = builtinRules[base] ?? [] }
        func words(_ list: [String]?) -> String? {
            guard let list, !list.isEmpty else { return nil }
            return #"\b(?:"# + list.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
        }
        var extra: [Rule] = []
        if base == nil {
            extra.append(Rule(#"\b\d+(?:\.\d+)?\b"#, .number))
            extra.append(Rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, .string))
        }
        if let k = words(language.keywords) { extra.append(Rule(k, .keyword)) }
        if let c = words(language.control) { extra.append(Rule(c, .control)) }
        if let line = language.lineComment, !line.isEmpty {
            extra.append(Rule(NSRegularExpression.escapedPattern(for: line) + ".*$", .comment))
        }
        if let block = language.blockComment, block.count == 2 {
            extra.append(Rule(NSRegularExpression.escapedPattern(for: block[0]) + #"[\s\S]*?"# + NSRegularExpression.escapedPattern(for: block[1]), .comment))
        }
        for raw in language.rules ?? [] {
            if let token = Token(rawValue: raw.token),
               let rule = Rule(safe: raw.pattern, token, group: raw.group ?? 0,
                               options: raw.caseInsensitive == true ? [.caseInsensitive] : []) {
                extra.append(rule)
            }
        }
        // Keywords before strings/comments (so a keyword inside a string
        // still reads as string), which is where the base's own sit.
        if let firstStringOrComment = rules.firstIndex(where: { $0.token == .string || $0.token == .comment }) {
            rules.insert(contentsOf: extra.filter { $0.token != .comment && $0.token != .string }, at: firstStringOrComment)
            rules.append(contentsOf: extra.filter { $0.token == .comment || $0.token == .string })
        } else {
            rules.append(contentsOf: extra)
        }
        return rules
    }

    /// Paints `storage` in place: full range reset to `plain`, then each
    /// rule's matches in its colour.
    static func highlight(_ storage: NSTextStorage, language: Language, font: NSFont) {
        let theme = theme
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: theme.plain], range: full)
        let text = storage.string
        for rule in rules(for: language) {
            let color = theme.color(rule.token)
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        storage.endEditing()
    }
}

extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
