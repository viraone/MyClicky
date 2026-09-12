import AppKit
import SwiftUI

/// AppKit owns the cursor rectangle so leaving or hiding the window cannot leak a cursor push.
struct PanelTopResizeHandle: NSViewRepresentable {
    var onResize: (CGSize?) -> Void

    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.onResize = onResize
    }

    static func dismantleNSView(_ view: ResizeView, coordinator: ()) {
        view.finishDrag()
        view.discardCursorRects()
        NotificationCenter.default.removeObserver(view)
        view.onResize = nil
    }

    final class ResizeView: NSView {
        var onResize: ((CGSize?) -> Void)?
        private var dragging = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(visibleRect, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            dragging = true
            onResize?(.zero)
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            onResize?(.zero) // The existing controller tracks the pointer in screen coordinates.
        }

        override func mouseUp(with event: NSEvent) { finishDrag() }
        override func cancelOperation(_ sender: Any?) { finishDrag() }
        override func viewDidHide() { finishDrag() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { finishDrag() }
            NotificationCenter.default.removeObserver(self)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                                                       name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowVisibilityChanged() {
            if window?.isVisible != true { finishDrag() }
        }

        func finishDrag() {
            guard dragging else { return }
            dragging = false
            onResize?(nil)
        }
    }
}
