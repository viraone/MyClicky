import AppKit

/// Watches a saved screen capture's file on disk for edits made outside
/// MyClicky — the normal flow is the user clicks the preview, which opens
/// the file in Preview.app, adds a markup arrow, and hits ⌘S. Polls the
/// modification date rather than the file descriptor since a safe-save can
/// swap the file's inode out from under a `DispatchSourceFileSystemObject`.
@MainActor
final class CaptureFileWatcher {
    /// Called with the freshly-reloaded image whenever the watched file's
    /// contents change on disk.
    var onChange: ((NSImage) -> Void)?

    private var timer: Timer?
    private var url: URL?
    private var lastModified: Date?

    func start(url: URL, interval: TimeInterval = 0.75) {
        stop()
        self.url = url
        lastModified = Self.modificationDate(of: url)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        url = nil
        lastModified = nil
    }

    private func poll() {
        guard let url, let modified = Self.modificationDate(of: url), modified != lastModified else { return }
        lastModified = modified
        guard let image = NSImage(contentsOf: url) else { return }
        onChange?(image)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
