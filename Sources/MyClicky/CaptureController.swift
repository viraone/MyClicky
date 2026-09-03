import AppKit

@MainActor
final class CaptureController {
    private let hotkey = HotkeyMonitor()
    private let capture = ScreenCaptureService()
    private let selection = SelectionOverlayController()
    private let preview = CapturePreviewPanel()
    private var busy = false
    /// When set, captures are previewed in the assistant panel's Capture +
    /// Dictate tab instead of the floating thumbnail.
    var onCaptured: ((NSImage, URL) -> Void)?

    func start() {
        hotkey.onTrigger = { [weak self] in self?.beginCapture() }
        hotkey.start()
    }

    /// Toggles the drag-to-select capture: starts it, or cancels an in-progress
    /// selection (used by the iOS remote's "5" key).
    func trigger() {
        if selection.isActive {
            selection.cancel()
        } else {
            // A stale `busy` (e.g. a save that never returned) must not block
            // new captures forever.
            busy = false
            beginCapture()
        }
    }

    private func beginCapture() {
        guard !busy else { return }
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        busy = true
        selection.begin(on: screen) { [weak self] rect in
            guard let self else { return }
            guard let rect else {
                self.busy = false
                return
            }
            Task {
                try? await self.captureAndSave(rect: rect, screen: screen)
                self.busy = false
            }
        }
    }

    private func captureAndSave(rect: CGRect, screen: NSScreen) async throws {
        let data = try await capture.captureCropped(rect: rect, screen: screen)
        let url = try Self.destinationURL()
        try data.write(to: url)
        ActivityLog.recordAction("capture", ["file": url.lastPathComponent])
        if let image = NSImage(data: data) {
            if let onCaptured {
                // The assistant owns the clipboard (it pairs the image with dictation).
                onCaptured(image, url)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                preview.show(image: image, fileURL: url, on: screen)
            }
        }
    }

    private static func destinationURL() throws -> URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/VIRADETH_RESUME", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let usedNumbers = existing.compactMap { name -> Int? in
            guard name.hasPrefix("qw"), name.hasSuffix(".png") else { return nil }
            return Int(name.dropFirst(2).dropLast(4))
        }
        let nextNumber = (usedNumbers.max() ?? 0) + 1
        return folder.appendingPathComponent("qw\(nextNumber).png")
    }
}
