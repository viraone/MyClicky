import AppKit
import SwiftUI

/// The review screen for Gmail's large-attachment cleanup, mirroring
/// `DriveCleanupPanel`. There's no Claude pass here — message size is the
/// only signal, so the table is just sorted largest first and the person
/// ticks boxes.
@MainActor
final class GmailCleanupState: ObservableObject {
    enum Phase {
        case scanning(String)
        case review
        case trashing(done: Int, total: Int)
        case finished(trashed: Int, failed: Int, bytes: Int64)
        case failed(String)
    }

    @Published var phase: Phase = .scanning("Starting…")
    @Published var scannedCount = 0
    @Published var messages: [GmailService.LargeMessage] = []
    @Published var selection: Set<String> = []
    @Published var confirming = false
    @Published var confirmingEmptyTrash = false
    /// True only while an empty-trash-and-spam call is in flight.
    @Published var emptyingTrash = false
    @Published var emptyingTrashStatus: String?
    /// Count backing the "Empty Gmail Trash & Spam" button label. Optional:
    /// the button still works without it, just with generic copy.
    @Published var trashAndSpamCount: Int?

    var selectedMessages: [GmailService.LargeMessage] {
        messages.filter { selection.contains($0.id) }
    }
    var selectedBytes: Int64 {
        selectedMessages.reduce(0) { $0 + $1.sizeEstimate }
    }
    var totalBytes: Int64 {
        messages.reduce(0) { $0 + $1.sizeEstimate }
    }

    /// Moves the ticked threads to Gmail's trash. Set by the controller.
    var onTrash: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Permanently empties Gmail's Trash and Spam. Set by the controller.
    var onEmptyTrash: (() -> Void)?
}

@MainActor
final class GmailCleanupWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    let state = GmailCleanupState()
    /// Fired when the window goes away by any route, same as Drive's — a scan
    /// closed mid-flight must stop rather than keep running invisibly.
    var onClose: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: GmailCleanupView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Gmail Cleanup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleClosed() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()   // fires willClose, so handleClosed does the teardown
    }

    private func handleClosed() {
        // See DriveCleanupWindowController.handleClosed: releasing the window
        // from inside willClose crashes SwiftUI's own close-button gesture.
        onClose?()
    }
}

struct GmailCleanupView: View {
    @ObservedObject var state: GmailCleanupState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .alert("Move \(state.selection.count) message\(state.selection.count == 1 ? "" : "s") to Gmail's trash?",
               isPresented: $state.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash") { state.onTrash?() }
        } message: {
            Text("Frees \(DriveCleanupPlanner.byteText(state.selectedBytes)). "
                 + "They stay in Gmail's trash for 30 days, and you can restore any of them from there. "
                 + "Nothing is permanently deleted.")
        }
        .alert("Permanently delete everything in Gmail Trash and Spam?",
               isPresented: $state.confirmingEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash & Spam", role: .destructive) { state.onEmptyTrash?() }
        } message: {
            Text(emptyTrashMessage)
        }
    }

    private var emptyTrashMessage: String {
        let count = state.trashAndSpamCount
        let subject = count.map { "\($0) message\($0 == 1 ? "" : "s")" } ?? "Everything"
        return "\(subject) in Trash and Spam will be permanently deleted. "
             + "Unlike moving messages to Trash, this cannot be undone."
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gmail Cleanup").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if case .review = state.phase {
                HStack(spacing: 8) {
                    Button("Select all") { state.selection = Set(state.messages.map(\.id)) }
                    Button("Select none") { state.selection = [] }
                    Button("Select all over 25 MB") {
                        state.selection = Set(state.messages.filter { $0.sizeEstimate >= 25_000_000 }.map(\.id))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var subtitle: String {
        switch state.phase {
        case .scanning(let message):
            return message
        case .review:
            return "\(state.messages.count) messages over 10 MB · \(DriveCleanupPlanner.byteText(state.totalBytes)) total"
        case .trashing(let done, let total):
            return "Moving to trash — \(done) of \(total)…"
        case .finished(let trashed, let failed, let bytes):
            let base = "Moved \(trashed) message\(trashed == 1 ? "" : "s") to Gmail's trash · \(DriveCleanupPlanner.byteText(bytes)) freed"
            return failed > 0 ? base + " · \(failed) failed" : base + " · restorable for 30 days"
        case .failed(let message):
            return message
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .scanning, .trashing:
            VStack(spacing: 10) {
                ProgressView()
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review, .finished:
            if state.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle).foregroundStyle(.green)
                    Text("Nothing worth cleaning up.").font(.callout)
                    Text("No messages over 10 MB turned up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                columnHeader
                Divider()
                ForEach(Array(state.messages.enumerated()), id: \.element.id) { index, message in
                    row(message, striped: index.isMultiple(of: 2))
                    Divider()
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("").frame(width: 20)
            Text("From").frame(width: 160, alignment: .leading)
            Text("Subject").frame(maxWidth: .infinity, alignment: .leading)
            Text("Date").frame(width: 90, alignment: .trailing)
            Text("Size").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func row(_ message: GmailService.LargeMessage, striped: Bool) -> some View {
        let isSelected = state.selection.contains(message.id)
        let readOnly: Bool = { if case .finished = state.phase { return true } else { return false } }()
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { on in
                    if on { state.selection.insert(message.id) }
                    else { state.selection.remove(message.id) }
                }
            ))
            .labelsHidden()
            .disabled(readOnly)
            .frame(width: 20)

            Text(message.from)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 160, alignment: .leading)

            HStack(spacing: 6) {
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                if message.hasAttachment {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(dateText(message.date))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(DriveCleanupPlanner.byteText(message.sizeEstimate))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(striped ? Color.primary.opacity(0.035) : Color.clear)
        .opacity(readOnly && !isSelected ? 0.5 : 1)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .review = state.phase {
                Text("\(state.selection.count) selected · \(DriveCleanupPlanner.byteText(state.selectedBytes))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let status = state.emptyingTrashStatus, state.emptyingTrash {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showsEmptyTrashButton {
                Button(emptyTrashButtonTitle) { state.confirmingEmptyTrash = true }
                    .disabled(state.emptyingTrash)
            }
            switch state.phase {
            case .review:
                Button("Cancel") { state.onCancel?() }
                Button("Move \(state.selection.count) to Trash") { state.confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.selection.isEmpty)
            case .finished, .failed:
                Button("Close") { state.onCancel?() }
                    .keyboardShortcut(.defaultAction)
            case .scanning:
                Button("Cancel") { state.onCancel?() }
            case .trashing:
                EmptyView()
            }
        }
        .padding(12)
    }

    private var showsEmptyTrashButton: Bool {
        switch state.phase {
        case .review, .finished: return true
        default: return false
        }
    }

    private var emptyTrashButtonTitle: String {
        if let count = state.trashAndSpamCount {
            return "Empty Gmail Trash & Spam (\(count))"
        }
        return "Empty Gmail Trash & Spam"
    }
}
