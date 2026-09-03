import AppKit
import SwiftUI

/// A slim floating pill that shows a one-line message and fades out.
@MainActor
final class ToastController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, icon: String = "checkmark.circle.fill", tint: Color = .green,
              near point: NSPoint? = nil, duration: TimeInterval = 3) {
        dismiss(animated: false)
        let view = ToastView(message: message, icon: icon, tint: tint)
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(size)

        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 24)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(animated: true)
        }
    }

    private func dismiss(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private struct ToastView: View {
    let message: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 420)
        .background(
            Capsule()
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
        .fixedSize()
    }
}
