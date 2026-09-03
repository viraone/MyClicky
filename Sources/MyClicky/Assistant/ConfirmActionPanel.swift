import AppKit
import SwiftUI

/// A small floating confirmation dialog for destructive actions. The action
/// only runs on a deliberate button click — never voice alone.
@MainActor
final class ConfirmActionPanelController {
    private var panel: NSPanel?

    func show(
        title: String,
        message: String,
        confirmLabel: String,
        icon: String = "trash",
        tint: Color = .red,
        near point: NSPoint,
        on screen: NSScreen,
        onDecision: @escaping (Bool) -> Void
    ) {
        hide()
        let view = ConfirmActionView(
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            icon: icon,
            tint: tint,
            onDecision: { [weak self] confirmed in
                self?.hide()
                onDecision(confirmed)
            }
        )
        let hosting = NSHostingController(rootView: view)
        let panel = ConfirmPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
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
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 340, height: 170))

        var origin = NSPoint(x: point.x + 16, y: point.y - 190)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 348)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 178)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ConfirmPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ConfirmActionView: View {
    let title: String
    let message: String
    let confirmLabel: String
    let icon: String
    let tint: Color
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { onDecision(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1)))
                Button(confirmLabel) { onDecision(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.85)))
            }
        }
        .padding(16)
        .frame(width: 340, height: 170, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}
