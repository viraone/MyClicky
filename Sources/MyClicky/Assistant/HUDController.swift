import AppKit
import SwiftUI

/// The floating heads-up display: a click-through strip at the top of the
/// screen you're working on that shows the words as they're heard, what
/// Clicky decided they meant, and whether it went through (green), is
/// waiting on you (amber), or was taken back / refused (red). It never takes
/// focus and never takes a click; it fades a few seconds after the last thing
/// happened.
@MainActor
final class HUDController {
    enum Outcome: Equatable {
        case none, pending, ok, cancelled, failed

        var tint: Color {
            switch self {
            case .none: return .white.opacity(0.35)
            case .pending: return .yellow
            case .ok: return .green
            case .cancelled, .failed: return .red
            }
        }
    }

    @MainActor
    final class State: ObservableObject {
        @Published var transcript = ""
        @Published var decision = ""
        @Published var outcome: Outcome = .none
        @Published var listening = false
    }

    let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var screen: NSScreen?

    /// Words as they're heard; keeps the HUD up while someone is talking.
    func hear(_ transcript: String) {
        let words = transcript.split(separator: " ")
        state.transcript = words.suffix(14).joined(separator: " ")
        state.listening = true
        if state.outcome != .pending { state.outcome = .none }
        show(hideAfter: 6)
    }

    /// What the words were taken to mean, before anything happens.
    func decide(_ text: String, outcome: Outcome = .none) {
        state.decision = text
        state.outcome = outcome
        state.listening = false
        show(hideAfter: outcome == .pending ? 60 : 6)
    }

    /// The result: green went through, red taken back / refused.
    func report(_ text: String, ok: Bool) {
        state.decision = text
        state.outcome = ok ? .ok : .cancelled
        state.listening = false
        show(hideAfter: 5)
    }

    /// Where the strip lives: the display you're working on.
    func attach(to screen: NSScreen?) {
        guard let screen, screen != self.screen else { return }
        self.screen = screen
        if let panel { place(panel, on: screen) }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func show(hideAfter seconds: TimeInterval) {
        let panel = self.panel ?? makePanel()
        if panel.alphaValue < 1 || !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: HUDView(state: state))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setContentSize(NSSize(width: 560, height: 64))
        place(panel, on: screen ?? NSScreen.main ?? NSScreen.screens[0])
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10))
    }
}

private struct HUDView: View {
    @ObservedObject var state: HUDController.State

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(state.outcome.tint)
                .frame(width: 10, height: 10)
                .shadow(color: state.outcome.tint.opacity(0.8), radius: state.outcome == .none ? 0 : 6)
                .overlay {
                    if state.listening {
                        Circle().strokeBorder(Color.red.opacity(0.9), lineWidth: 2)
                            .frame(width: 16, height: 16)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: state.outcome)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.transcript.isEmpty ? " " : state.transcript)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(state.listening ? 0.95 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(state.decision.isEmpty ? " " : state.decision)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 560, height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
    }
}
