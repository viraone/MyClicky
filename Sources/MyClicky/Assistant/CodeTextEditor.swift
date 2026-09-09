import AppKit
import SwiftUI

/// The editable file preview on the Peeky Code tab. A plain `TextEditor`
/// would do for typing, but Peeky has no menu bar, so ⌘F would never reach
/// it. This wraps `NSTextView` directly, turns on the system find bar
/// (incremental, highlights every match, ⌘G / ⇧⌘G to step through) and
/// handles the find keys itself — the same keys as VS Code.
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        // Programmatic change (file switched, Apply pressed): replace the
        // text but keep the caret somewhere sensible.
        let selected = textView.selectedRange()
        textView.string = text
        let end = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selected.location, end), length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        weak var textView: NSTextView?
        init(_ parent: CodeTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// `NSTextView` that maps the usual find keys to the find bar, since there
/// is no Edit ▸ Find menu in Peeky to do it.
final class FindableTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: NSTextFinder.Action?
        switch (key, flags) {
        case ("f", [.command]):           action = .showFindInterface
        case ("f", [.command, .option]):  action = .showReplaceInterface
        case ("g", [.command]):           action = .nextMatch
        case ("g", [.command, .shift]):   action = .previousMatch
        case ("e", [.command]):           action = .setSearchString
        default: break
        }
        if let action {
            // NSTextFinder reads the action off the sender's tag.
            let item = NSMenuItem()
            item.tag = action.rawValue
            performFindPanelAction(item)
            return
        }
        super.keyDown(with: event)
    }

    /// Esc closes the find bar first; only a second Esc reaches the panel.
    override func cancelOperation(_ sender: Any?) {
        if let scroll = enclosingScrollView, scroll.isFindBarVisible {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performFindPanelAction(item)
            return
        }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }
}
