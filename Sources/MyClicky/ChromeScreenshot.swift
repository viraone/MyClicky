import AppKit

/// Copies a full-resolution PNG of the display Google Chrome's front window
/// is on to the clipboard, ready to paste into a chat. Nothing touches disk.
@MainActor
enum ChromeScreenshot {
    enum Outcome {
        case copied
        case chromeNotOpen
        case failed(String)
    }

    static func copyEntireScreenToClipboard(capture: ScreenCaptureService) async -> Outcome {
        guard let screen = frontmostChromeWindowScreen() else { return .chromeNotOpen }
        do {
            let png = try await capture.captureDisplayPNG(screen: screen)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            return .copied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The display holding Chrome's frontmost window, or nil when Chrome is
    /// not running or has no real window on screen.
    static func frontmostChromeWindowScreen() -> NSScreen? {
        guard let chrome = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome")
            .first else { return nil }
        let chromePID = Int(chrome.processIdentifier)
        // Windows arrive front-to-back, so the first match is the frontmost.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? Int) == chromePID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width > 100, bounds.height > 100 else { continue }

            // kCGWindowBounds is global top-left-origin; NSScreen frames have
            // a bottom-left origin mirrored around the primary display's top.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoaRect = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                   width: bounds.width, height: bounds.height)
            let centre = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) {
                return screen
            }
            // Straddling displays: take the one showing most of the window.
            guard let best = NSScreen.screens.max(by: {
                $0.frame.intersection(cocoaRect).area < $1.frame.intersection(cocoaRect).area
            }), !best.frame.intersection(cocoaRect).isEmpty else { return nil }
            return best
        }
        return nil
    }
}

private extension CGRect {
    /// Zero when the rects don't meet, so a non-overlapping screen never wins.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
