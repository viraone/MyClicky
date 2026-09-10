import AppKit
import SwiftUI

/// The review screen for Drive cleanup, and the only path to a trash call.
///
/// The window is deliberately a plain, resizable `NSWindow` rather than the
/// floating panel the rest of the app uses: this is a table you sit and read,
/// sometimes hundreds of rows long, not a heads-up display.
@MainActor
final class DriveCleanupState: ObservableObject {
    enum Phase {
        case scanning(String)
        case review
        case trashing(done: Int, total: Int)
        case finished(trashed: Int, failed: Int, bytes: Int64)
        case failed(String)
    }

    @Published var phase: Phase = .scanning("Starting…")
    @Published var scannedCount = 0
    @Published var candidates: [DriveCleanupPlanner.Candidate] = []
    /// Total files that tripped a heuristic, which can exceed `candidates`
    /// when the shortlist cap trims the tail.
    @Published var signalledCount = 0
    /// Ticked rows. Seeded from Claude's flags, but the person decides.
    @Published var selection: Set<String> = []
    @Published var confirming = false
    /// Account storage totals for the quota meter. Optional: the cleanup flow
    /// still works if this fetch fails, it just skips the meter.
    @Published var quota: DriveService.StorageQuota?
    @Published var confirmingEmptyTrash = false
    /// True only while an empty-trash call is in flight, so the button can't
    /// be double-tapped.
    @Published var emptyingTrash = false

    var selectedCandidates: [DriveCleanupPlanner.Candidate] {
        candidates.filter { selection.contains($0.id) }
    }
    var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.file.effectiveBytes }
    }

    /// Moves the ticked files to Drive's trash. Set by the controller.
    var onTrash: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Permanently empties Drive's trash. Set by the controller.
    var onEmptyTrash: (() -> Void)?
}

/// Pure quota-projection arithmetic, kept apart from the view so it's unit
/// testable without SwiftUI.
enum DriveQuotaMath {
    /// Google's free tier. Google's "15 GB" is 15 GiB — the `about` endpoint
    /// reports `limit` as 16,106,127,360 bytes for free accounts — and its UI
    /// formats usage in binary units too, so everything here follows suit.
    static let freeTierBytes: Int64 = 15 * 1024 * 1024 * 1024

    /// The account's cap for planning purposes. Unlimited accounts (no
    /// `limit`) and paid plans above the free tier both collapse to the free
    /// tier, since the point of this meter is life after cancelling Google One.
    static func targetBytes(limit: Int64?) -> Int64 {
        guard let limit else { return freeTierBytes }
        return min(limit, freeTierBytes)
    }

    struct Projection {
        let remainingBytes: Int64
        let overBytes: Int64
        let isUnderLimit: Bool
    }

    static func projection(usage: Int64, selectedBytes: Int64, target: Int64) -> Projection {
        let remaining = max(0, usage - selectedBytes)
        let over = max(0, remaining - target)
        return Projection(remainingBytes: remaining, overBytes: over, isUnderLimit: over == 0)
    }
}

@MainActor
final class DriveCleanupWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    let state = DriveCleanupState()
    /// Fired when the window goes away by any route — including the red close
    /// button and ⌘W, which bypass the Cancel button entirely. Without this a
    /// scan closed mid-flight keeps running invisibly, still calling Claude
    /// and still spending money on a window nobody is looking at.
    var onClose: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DriveCleanupView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Drive Cleanup"
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
        // Deliberately keeps the window and its observer alive.
        //
        // This fires from NSWindow.willCloseNotification, which arrives while
        // SwiftUI is still dispatching the close button's gesture. Releasing
        // the window here frees the hosting controller and the view that owns
        // that button, and the app segfaults inside _ButtonGesture. The window
        // is reused by `show()` instead — it's one window, and keeping it
        // costs nothing next to crashing.
        onClose?()
    }
}

struct DriveCleanupView: View {
    @ObservedObject var state: DriveCleanupState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .alert("Move \(state.selection.count) file\(state.selection.count == 1 ? "" : "s") to Drive's trash?",
               isPresented: $state.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash") { state.onTrash?() }
        } message: {
            Text("Frees \(DriveCleanupPlanner.byteText(state.selectedBytes)). "
                 + "They stay in Drive's trash for 30 days, and you can restore any of them from there. "
                 + "Nothing is permanently deleted.")
        }
        .alert("Permanently delete everything in Drive Trash?",
               isPresented: $state.confirmingEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Empty Trash", role: .destructive) { state.onEmptyTrash?() }
        } message: {
            Text("\(DriveCleanupPlanner.byteText(state.quota?.usageInDriveTrash ?? 0)) will be freed. "
                 + "Unlike moving files to Trash, this cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drive Cleanup").font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if case .review = state.phase {
                    HStack(spacing: 8) {
                        Button("Select all") { state.selection = Set(state.candidates.map(\.id)) }
                        Button("Select none") { state.selection = [] }
                        Button("Claude's picks") {
                            state.selection = Set(state.candidates.filter(\.flagged).map(\.id))
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let quota = state.quota {
                quotaMeter(quota)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func quotaMeter(_ quota: DriveService.StorageQuota) -> some View {
        let target = DriveQuotaMath.targetBytes(limit: quota.limit)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(DriveCleanupPlanner.byteText(quota.usage)) used of \(DriveCleanupPlanner.byteText(target))")
                    .font(.system(size: 12, weight: .medium))
                Text("Free tier is 15 GB after cancelling Google One")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if case .review = state.phase {
                let projection = DriveQuotaMath.projection(
                    usage: quota.usage, selectedBytes: state.selectedBytes, target: target)
                HStack(spacing: 4) {
                    Text("After this cleanup: \(DriveCleanupPlanner.byteText(projection.remainingBytes))")
                    Text(projection.isUnderLimit
                         ? "— under the limit"
                         : "— still \(DriveCleanupPlanner.byteText(projection.overBytes)) over")
                        .fontWeight(.medium)
                }
                .font(.system(size: 11))
                .foregroundStyle(projection.isUnderLimit ? .green : .orange)
            }
            if quota.usageInDriveTrash > 0 {
                Text("\(DriveCleanupPlanner.byteText(quota.usageInDriveTrash)) in Drive Trash")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .scanning(let message):
            return message
        case .review:
            let flagged = state.candidates.filter(\.flagged).count
            let total = state.candidates.reduce(Int64(0)) { $0 + $1.file.effectiveBytes }
            let shown = state.signalledCount > state.candidates.count
                ? "\(state.candidates.count) of \(state.signalledCount) worth a look (largest first)"
                : "\(state.candidates.count) worth a look"
            return "\(state.scannedCount) files scanned · \(shown) · "
                 + "\(flagged) flagged by Claude · \(DriveCleanupPlanner.byteText(total)) in view"
        case .trashing(let done, let total):
            return "Moving to trash — \(done) of \(total)…"
        case .finished(let trashed, let failed, let bytes):
            let base = "Moved \(trashed) file\(trashed == 1 ? "" : "s") to Drive's trash · \(DriveCleanupPlanner.byteText(bytes)) freed"
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
            if state.candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle).foregroundStyle(.green)
                    Text("Nothing worth cleaning up.").font(.callout)
                    Text("No empty documents, stale large files, or duplicates turned up.")
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
                ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, candidate in
                    row(candidate, striped: index.isMultiple(of: 2))
                    Divider()
                }
            }
        }
    }

    private func row(_ candidate: DriveCleanupPlanner.Candidate, striped: Bool) -> some View {
        let isSelected = state.selection.contains(candidate.id)
        let readOnly: Bool = { if case .finished = state.phase { return true } else { return false } }()
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { on in
                    if on { state.selection.insert(candidate.id) }
                    else { state.selection.remove(candidate.id) }
                }
            ))
            .labelsHidden()
            .disabled(readOnly)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.file.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if candidate.flagged {
                        Text("FLAGGED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                            .foregroundStyle(.orange)
                    }
                    Text(candidate.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(DriveCleanupPlanner.byteText(candidate.file.effectiveBytes))
                    .font(.system(size: 11, design: .monospaced))
                Text(DriveCleanupPlanner.friendlyType(candidate.file.mimeType))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)

            Text(lastTouched(candidate.file))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            // Straight to the file in Drive, so a questionable row can be
            // checked before it's ticked rather than trusted blind.
            if let link = candidate.file.webViewLink, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open in Drive")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(striped ? Color.primary.opacity(0.035) : Color.clear)
        .opacity(readOnly && !isSelected ? 0.5 : 1)
    }

    private func lastTouched(_ file: DriveService.InventoryFile) -> String {
        guard let date = [file.viewedByMeTime, file.modifiedTime].compactMap({ $0 }).max() else {
            return "never opened"
        }
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

    /// Only offered where it's relevant (review/finished) and where there's
    /// actually something in the trash to empty.
    private var showsEmptyTrashButton: Bool {
        guard (state.quota?.usageInDriveTrash ?? 0) > 0 else { return false }
        switch state.phase {
        case .review, .finished: return true
        default: return false
        }
    }

    private var emptyTrashButtonTitle: String {
        "Empty Trash (\(DriveCleanupPlanner.byteText(state.quota?.usageInDriveTrash ?? 0)))"
    }
}
