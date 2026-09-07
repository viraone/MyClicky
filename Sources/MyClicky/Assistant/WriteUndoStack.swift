import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "writeundo")

/// A field the undo stack can put a value back into. `AXWriteTarget` is the
/// real one; tests use a fake so the stack's coalescing/cap/pop logic can be
/// exercised without live Accessibility.
@MainActor
protocol WriteUndoTarget {
    /// Identity of the field across snapshots: two handles on the same
    /// compose box must compare equal, so a preview begun on one handle
    /// coalesces with the polished write made through another.
    var undoKey: AnyHashable { get }
    /// False once the field is gone (conversation closed, app quit).
    var isValid: Bool { get }
    /// What the field holds right now, nil when it can't be read.
    func currentValue() -> String?
    /// Writes `value` back the same way it went in — in the background,
    /// never stealing focus — and verifies.
    func restore(_ value: String) -> BackgroundWriteResult
    /// On-screen frame (AppKit coordinates) for the confirmation ring.
    var frame: CGRect? { get }
}

/// One background write that can be reverted.
struct WriteUndoEntry {
    let target: any WriteUndoTarget
    let previousValue: String
    let newValue: String
    let timestamp: Date
    /// Where it was written, for the spoken confirmation ("Messages · Dino Dad").
    let label: String
}

/// What `WriteUndoStack.undoLast()` did, ready to be spoken or toasted.
enum UndoWriteOutcome: Equatable {
    /// `previousValue` is back in the field. `forced` when the field no
    /// longer held what Clicky last wrote (the user typed since) — it was
    /// restored anyway, but the caller should say so.
    case restored(label: String, previousValue: String, forced: Bool)
    case nothingToUndo
    /// The field the last write went into isn't there any more.
    case targetGone(label: String)
    /// The write-back was attempted and didn't land.
    case failed(label: String, BackgroundWriteResult)

    /// One short line for the panel / phone / speech.
    var message: String {
        switch self {
        case .restored(let label, let previous, let forced):
            let what = previous.isEmpty ? "cleared the text I'd written" : "put back “\(Self.clip(previous))”"
            return forced ? "Undone — \(what) in \(label), over what was typed since." : "Undone — \(what) in \(label)."
        case .nothingToUndo:
            return "Nothing to undo."
        case .targetGone(let label):
            return "Couldn't undo — the field in \(label) isn't there any more."
        case .failed(let label, _):
            return "Couldn't undo the last write in \(label)."
        }
    }

    var ok: Bool {
        if case .restored = self { return true }
        return false
    }

    private static func clip(_ text: String, to limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}

/// Revert-last-write for Clicky's background writes. `AXActions.
/// writeTextInBackground` records every real change here (never streaming
/// partials — see `beginCoalescing`), and "undo that" pops the most recent
/// entry and writes its previous value back through the same no-focus path.
///
/// Depth is capped (oldest dropped first) and entries whose field has gone
/// away are pruned before each undo.
@MainActor
final class WriteUndoStack {
    static let shared = WriteUndoStack()

    let capacity: Int
    private(set) var entries: [WriteUndoEntry] = []
    /// Fields with a live preview in progress: the value they held before the
    /// preview started, so the eventual real write is undone to *that*, not
    /// to the last partial transcript.
    private var coalescing: [AnyHashable: (previousValue: String, label: String?)] = [:]

    init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var last: WriteUndoEntry? { entries.last }

    // MARK: - Recording

    /// A streaming preview is about to start writing partials into `target`.
    /// The partials themselves are written with `undoable: false`; when the
    /// polished text lands (a normal, undoable write), its entry's previous
    /// value is `previousValue` from here — one undo step for the whole
    /// sentence. `label` overrides the write's label if given.
    func beginCoalescing(_ target: any WriteUndoTarget, previousValue: String, label: String? = nil) {
        coalescing[target.undoKey] = (previousValue, label)
    }

    /// The preview was discarded (the words were a command) without a real
    /// write landing — forget the pending previous value.
    func endCoalescing(_ target: any WriteUndoTarget) {
        coalescing.removeValue(forKey: target.undoKey)
    }

    var isCoalescing: Bool { !coalescing.isEmpty }

    /// Snapshots a write that has just landed. Pushes only when the field
    /// actually changed — from the coalesced starting value if a preview was
    /// in progress, else from `previousValue` — so a `.suspectedNoop` write
    /// on a field with no pending preview records nothing. Returns whether an
    /// entry was pushed.
    @discardableResult
    func record(target: any WriteUndoTarget, previousValue: String, newValue: String, label: String) -> Bool {
        let pending = coalescing.removeValue(forKey: target.undoKey)
        let effectivePrevious = pending?.previousValue ?? previousValue
        guard AXActions.normalizedLines(effectivePrevious) != AXActions.normalizedLines(newValue) else {
            return false
        }
        entries.append(WriteUndoEntry(target: target, previousValue: effectivePrevious, newValue: newValue,
                                      timestamp: Date(), label: pending?.label ?? label))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        log.notice("recorded write to \(label, privacy: .public) (\(effectivePrevious.count) → \(newValue.count) chars); depth \(self.entries.count)")
        return true
    }

    /// Drops entries whose field no longer exists.
    func prune() {
        let before = entries.count
        entries.removeAll { !$0.target.isValid }
        if entries.count != before {
            log.notice("pruned \(before - self.entries.count) entries with missing fields")
        }
    }

    // MARK: - Undo

    /// Pops the most recent write and puts its previous value back, in the
    /// background. If the field has moved on since (user typed), it is still
    /// restored, but the outcome says `forced`.
    func undoLast() -> UndoWriteOutcome {
        prune()
        guard let entry = entries.popLast() else {
            log.notice("undo: stack empty")
            return .nothingToUndo
        }
        guard entry.target.isValid else { return .targetGone(label: entry.label) }
        let current = entry.target.currentValue()
        let forced = current.map { AXActions.normalizedLines($0) != AXActions.normalizedLines(entry.newValue) } ?? false
        let result = entry.target.restore(entry.previousValue)
        guard result.landed else {
            log.notice("undo: write-back to \(entry.label, privacy: .public) failed: \(String(describing: result), privacy: .public)")
            return .failed(label: entry.label, result)
        }
        log.notice("undo: restored \(entry.previousValue.count) chars in \(entry.label, privacy: .public)\(forced ? " (forced — field had changed)" : "", privacy: .public)")
        return .restored(label: entry.label, previousValue: entry.previousValue, forced: forced)
    }

    func removeAll() {
        entries.removeAll()
        coalescing.removeAll()
    }

    /// Drops every entry for one field — used when the field's content has
    /// been committed some other way (a terminal line that was run), so
    /// "undo" doesn't try to take back something that's already gone.
    func forget(key: AnyHashable) {
        entries.removeAll { $0.target.undoKey == key }
        coalescing.removeValue(forKey: key)
    }
}

// MARK: - AXUIElement target

/// `AXUIElement` identity is a CF thing — two lookups of the same field give
/// two references — so equality goes through `CFEqual`/`CFHash`, which
/// compare the underlying element, not the wrapper.
struct AXElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// The real target: a text field reached through Accessibility, written back
/// via `AXActions.writeTextInBackground` with undo recording off (the
/// revert itself is not something to undo).
struct AXWriteTarget: WriteUndoTarget {
    let element: AXUIElement

    var undoKey: AnyHashable { AXElementKey(element: element) }

    var isValid: Bool {
        AccessibilityFinder.attribute(element, kAXRoleAttribute) != nil
    }

    func currentValue() -> String? {
        AccessibilityFinder.attribute(element, kAXValueAttribute) as? String
    }

    func restore(_ value: String) -> BackgroundWriteResult {
        AXActions.writeTextInBackground(to: element, text: value, undoable: false)
    }

    var frame: CGRect? { AccessibilityFinder.frame(of: element) }
}
