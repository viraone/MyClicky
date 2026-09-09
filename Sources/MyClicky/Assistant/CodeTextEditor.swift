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
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
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
                                     .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                                     .paragraphStyle: textView.defaultParagraphStyle!]

        textView.onFind = { [weak coordinator = context.coordinator] in coordinator?.parent.onFind?() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape?() }

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            // Programmatic change (file switched, Apply pressed): replace the
            // text but keep the caret somewhere sensible.
            let selected = textView.selectedRange()
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
        }
        applyHighlights(to: textView, coordinator: context.coordinator)
    }

    private func applyHighlights(to textView: NSTextView, coordinator: Coordinator) {
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
        init(_ parent: CodeTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// `NSTextView` that hands ⌘F and Esc to Peeky's own find bar.
final class FindableTextView: NSTextView {
    var onFind: (() -> Void)?
    var onEscape: (() -> Void)?

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
