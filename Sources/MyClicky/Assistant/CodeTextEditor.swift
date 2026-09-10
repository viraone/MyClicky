import AppKit
import SwiftUI

/// The editable file preview on the Peeky Code tab. Wraps `NSTextView`
/// directly so Peeky can paint find matches and pick up ⌘F itself — a
/// plain `TextEditor` gives no way to do either.
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Ranges to mark as matches; `current` is drawn brighter and scrolled to.
    var highlights: [NSRange] = []
    var current: NSRange?
    var onFind: (() -> Void)?
    var onEscape: (() -> Void)?
    var language: SyntaxHighlighter.Language = .other
    /// Scroll to and select this 1-based line once, then call `onDidJump`.
    var jumpToLine: Int?
    var jumpLineCount = 1
    var onDidJump: (() -> Void)?
    var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = FindableTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.textColor = SyntaxHighlighter.plain
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.systemBlue.withAlphaComponent(0.45)]
        textView.defaultParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            return style
        }()
        textView.typingAttributes = [.font: font,
                                     .foregroundColor: SyntaxHighlighter.plain,
                                     .paragraphStyle: textView.defaultParagraphStyle!]
        if let storage = textView.textStorage {
            SyntaxHighlighter.highlight(storage, language: language, font: font)
        }
        context.coordinator.language = language

        textView.onFind = { [weak coordinator = context.coordinator] in coordinator?.parent.onFind?() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape?() }

        scroll.documentView = textView
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = CodeLineNumberRuler(textView: textView, scrollView: scroll)
        scroll.rulersVisible = true
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            // Programmatic change (file switched, Apply pressed): replace the
            // text through the undo manager so a single ⌘Z reverts it, but
            // keep the caret somewhere sensible.
            let selected = textView.selectedRange()
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: full, replacementString: text) {
                textView.undoManager?.beginUndoGrouping()
                textView.textStorage?.replaceCharacters(in: full, with: text)
                textView.didChangeText()
                textView.undoManager?.setActionName("Apply")
                textView.undoManager?.endUndoGrouping()
            }
            (scroll.verticalRulerView as? CodeLineNumberRuler)?.rebuildLines()
            (textView as? FindableTextView)?.refreshBracketMatch()
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
            if let storage = textView.textStorage {
                SyntaxHighlighter.highlight(storage, language: language, font: font)
            }
        } else if language != context.coordinator.language, let storage = textView.textStorage {
            SyntaxHighlighter.highlight(storage, language: language, font: font)
        }
        context.coordinator.language = language
        applyHighlights(to: textView, coordinator: context.coordinator)
        if let line = jumpToLine, line > 0 {
            let ns = textView.string as NSString
            var index = 0, current = 1
            while current < line, index < ns.length {
                let r = ns.lineRange(for: NSRange(location: index, length: 0))
                index = NSMaxRange(r); current += 1
            }
            var range = ns.lineRange(for: NSRange(location: min(index, max(ns.length - 1, 0)), length: 0))
            var extra = jumpLineCount - 1
            while extra > 0, NSMaxRange(range) < ns.length {
                let next = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                range = NSUnionRange(range, next); extra -= 1
            }
            let onDidJump = onDidJump
            // A freshly shown editor has no size yet, and fresh text hasn't
            // been laid out — scrolling then lands at the top. Wait until
            // the view is real (a few frames at most), then go.
            func attempt(_ remaining: Int) {
                let ready = textView.visibleRect.height > 0 && textView.frame.width > 0
                if ready || remaining == 0 {
                    textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                    onDidJump?()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { attempt(remaining - 1) }
                }
            }
            DispatchQueue.main.async { attempt(40) }
        }
    }

    fileprivate func applyHighlights(to textView: NSTextView, coordinator: Coordinator) {
        guard let layout = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let key = highlights.map { "\($0.location):\($0.length)" }.joined(separator: ",") + "|\(current.map { "\($0.location)" } ?? "")"
        guard key != coordinator.highlightKey else { return }
        coordinator.highlightKey = key
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for range in highlights where NSMaxRange(range) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), forCharacterRange: range)
        }
        if let current, NSMaxRange(current) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.75), forCharacterRange: current)
            textView.scrollRangeToVisible(current)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        weak var textView: NSTextView?
        var highlightKey = ""
        var language: SyntaxHighlighter.Language = .other
        private var recolor: DispatchWorkItem?
        init(_ parent: CodeTextEditor) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? FindableTextView)?.refreshBracketMatch()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // Re-colour a beat after typing stops; a full pass on every
            // keystroke would stutter on a 4,000-line file.
            recolor?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, let storage = textView.textStorage else { return }
                let selected = textView.selectedRange()
                SyntaxHighlighter.highlight(storage, language: self.language, font: self.parent.font)
                textView.setSelectedRange(selected)
                self.highlightKey = ""
                self.parent.applyHighlights(to: textView, coordinator: self)
            }
            recolor = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

/// `NSTextView` that hands ⌘F and Esc to Peeky's own find bar, outlines
/// the bracket pair around the caret, and selects a whole block when a
/// bracket is double-clicked.
final class FindableTextView: NSTextView {
    var onFind: (() -> Void)?
    var onEscape: (() -> Void)?
    private var bracketPair: BracketMatcher.Pair?
    private var lastCaretLine: NSRange?

    /// Includes wrapped fragments, and the extra insertion line after a final newline.
    var currentLineRect: NSRect? {
        let selection = selectedRange()
        guard selection.length == 0, selection.location <= (string as NSString).length,
              let layout = layoutManager, let container = textContainer else { return nil }
        let line = (string as NSString).lineRange(for: selection)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        var band = line.length == 0 ? layout.extraLineFragmentRect
            : layout.boundingRect(forGlyphRange: glyphs, in: container)
        if band.height == 0 {
            band.size.height = layout.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular))
        }
        band.origin = NSPoint(x: bounds.minX, y: band.minY + textContainerOrigin.y)
        band.size.width = bounds.width
        return band
    }

    func refreshBracketMatch() {
        let selected = selectedRange()
        let next = selected.length == 0 ? BracketMatcher.pair(in: string as NSString, caret: selected.location) : nil
        let caretLine = selected.length == 0 ? (string as NSString).lineRange(for: selected) : nil
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        guard next != bracketPair || caretLine != lastCaretLine else { return }
        lastCaretLine = caretLine
        bracketPair = next
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let band = currentLineRect, band.intersects(rect) {
            NSColor.white.withAlphaComponent(0.05).setFill()
            band.intersection(rect).fill(using: .sourceOver)
        }
        guard let pair = bracketPair, let layout = layoutManager, let container = textContainer else { return }
        let color = NSColor.white.withAlphaComponent(0.55)
        for index in [pair.open, pair.close] {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += textContainerOrigin.x
            box.origin.y += textContainerOrigin.y
            box = box.insetBy(dx: -0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.10).setFill(); path.fill()
            color.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            let ns = string as NSString
            for candidate in [index, index - 1] where candidate >= 0 && candidate < ns.length {
                if let pair = BracketMatcher.pair(in: ns, caret: candidate + 1), pair.open == candidate || pair.close == candidate {
                    setSelectedRange(NSRange(location: pair.open, length: pair.close - pair.open + 1))
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "f", let onFind {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }
}

/// UTF-16 offsets match NSLayoutManager's character indices, including emoji.
struct CodeLineIndex {
    let starts: [Int]

    init(_ text: String) {
        starts = [0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
    }

    func line(at character: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }
}

final class CodeLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private(set) var lines = CodeLineIndex("")
    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    override var isOpaque: Bool { false }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        rebuildLines()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw(_ notification: Notification) { needsDisplay = true }
    @objc private func textChanged(_ notification: Notification) {
        rebuildLines()
        textView?.needsDisplay = true
    }

    func rebuildLines() {
        lines = CodeLineIndex(textView?.string ?? "")
        let digits = String(lines.starts.count).count
        ruleThickness = ceil((String(repeating: "0", count: digits) as NSString)
            .size(withAttributes: [.font: numberFont]).width) + 16
        needsDisplay = true
    }

    // Avoid NSRulerView's opaque default background and ruler markings.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let selection = textView.selectedRange()
        let caretLine = selection.length == 0 ? lines.line(at: selection.location) : nil
        func drawNumber(_ line: Int, fragment: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor.white.withAlphaComponent(line == caretLine ? 0.7 : 0.28)
            ]
            let label = String(line) as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - 8 - size.width,
                                   y: point.y + (fragment.height - size.height) / 2), withAttributes: attributes)
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            let line = self.lines.line(at: character)
            // Continuation fragments of a wrapped line get no additional number.
            if self.lines.starts[line - 1] == character { drawNumber(line, fragment: fragment) }
        }
        if layout.extraLineFragmentTextContainer === container,
           lines.starts.last == (textView.string as NSString).length,
           layout.extraLineFragmentRect.intersects(visible) {
            drawNumber(lines.starts.count, fragment: layout.extraLineFragmentRect)
        }
    }
}

/// Finds the `{}` `()` `[]` partner of the bracket next to the caret,
/// skipping brackets that sit inside string literals.
enum BracketMatcher {
    struct Pair: Equatable { let open: Int; let close: Int }

    private static let opens: [unichar: unichar] = [123: 125, 40: 41, 91: 93]   // { ( [
    private static let closes: [unichar: unichar] = [125: 123, 41: 40, 93: 91]  // } ) ]

    /// The pair for the bracket just before the caret, else just after it.
    static func pair(in text: NSString, caret: Int) -> Pair? {
        for index in [caret - 1, caret] where index >= 0 && index < text.length {
            let ch = text.character(at: index)
            if let close = opens[ch], let partner = scan(text, from: index, open: ch, close: close, forward: true) {
                return Pair(open: index, close: partner)
            }
            if let open = closes[ch], let partner = scan(text, from: index, open: open, close: ch, forward: false) {
                return Pair(open: partner, close: index)
            }
        }
        return nil
    }

    /// Walks from `start`, counting depth, and returns the index where it
    /// comes back to zero. Brackets inside quotes on their line don't count.
    private static func scan(_ text: NSString, from start: Int, open: unichar, close: unichar, forward: Bool) -> Int? {
        if inString(text, at: start) { return nil }
        var depth = 0
        var index = start
        let step = forward ? 1 : -1
        while index >= 0 && index < text.length {
            let ch = text.character(at: index)
            if ch == open || ch == close, !inString(text, at: index) {
                depth += (ch == open) == forward ? 1 : -1
                if depth == 0 { return index }
            }
            index += step
        }
        return nil
    }

    /// True when `index` is inside a quoted string on its line.
    private static func inString(_ text: NSString, at index: Int) -> Bool {
        guard index >= 0, index < text.length else { return false }
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        var quote: unichar? = nil
        var i = line.location
        while i < index {
            let ch = text.character(at: i)
            if let q = quote {
                if ch == q, !(i > 0 && text.character(at: i - 1) == 92) { quote = nil }
            } else if ch == 34 || ch == 39 || ch == 96 {
                quote = ch
            }
            i += 1
        }
        return quote != nil
    }
}
