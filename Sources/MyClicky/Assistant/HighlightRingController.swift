import AppKit
import SwiftUI

/// Draws a temporary glowing ring over a region of the real screen, in a
/// transparent click-through window, then fades it away.
@MainActor
final class HighlightRingController {
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    /// `rect` is in AppKit screen coordinates (points, origin bottom-left).
    func show(over rect: CGRect, duration: TimeInterval = 4.0) {
        hide()

        let padding: CGFloat = 14
        let frame = rect.insetBy(dx: -padding, dy: -padding)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = NSHostingView(rootView: HighlightRingView())
        window.orderFrontRegardless()
        self.window = window

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window = nil
    }

    private func fadeOut() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in self?.hide() }
        })
    }
}

private struct HighlightRingView: View {
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.cyan, lineWidth: 3.5)
            .shadow(color: .cyan.opacity(0.9), radius: 8)
            .shadow(color: .cyan.opacity(0.5), radius: 16)
            .padding(4)
            .scaleEffect(pulsing ? 1.0 : 0.94)
            .opacity(pulsing ? 1.0 : 0.75)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
