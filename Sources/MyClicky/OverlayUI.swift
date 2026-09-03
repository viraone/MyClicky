import AppKit

/// Full-screen click-through-free overlay that lets the user drag out a
/// rectangle, showing live dimensions, à la Jing / Cmd-Shift-4.
final class SelectionOverlayView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dimColor = NSColor.black.withAlphaComponent(0.35)
        let path = NSBezierPath(rect: bounds)
        if currentRect.width > 0, currentRect.height > 0 {
            path.append(NSBezierPath(rect: currentRect))
            path.windingRule = .evenOdd
        }
        dimColor.setFill()
        path.fill()

        guard currentRect.width > 0, currentRect.height > 0 else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        border.stroke()

        let label = "\(Int(currentRect.width)) x \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let size = label.size(withAttributes: attrs)
        var origin = NSPoint(x: currentRect.minX, y: currentRect.maxY + 6)
        if origin.y + size.height > bounds.maxY { origin.y = currentRect.maxY - size.height - 6 }
        label.draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentRect = NSRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        startPoint = nil
        guard currentRect.width > 2, currentRect.height > 2,
              let windowRef = window else {
            onCancel?()
            return
        }
        let windowRect = convert(currentRect, to: nil)
        let screenRect = windowRef.convertToScreen(windowRect)
        onSelect?(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
        else { super.keyDown(with: event) }
    }
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, overlayView: SelectionOverlayView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }
}

@MainActor
final class SelectionOverlayController {
    private var window: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?

    /// True while the dim selection overlay is on screen.
    var isActive: Bool { window != nil }

    func begin(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let overlayView = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlayView.onSelect = { [weak self] rect in self?.finish(rect) }
        overlayView.onCancel = { [weak self] in self?.finish(nil) }
        let window = SelectionWindow(screen: screen, overlayView: overlayView)
        self.window = window
        NSCursor.crosshair.set()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
    }

    /// Dismisses the overlay as if the user pressed Escape (no capture).
    func cancel() {
        guard window != nil else { return }
        finish(nil)
    }

    private func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        NSCursor.arrow.set()
        let handler = completion
        completion = nil
        handler?(rect)
    }
}

/// Bottom-right thumbnail that briefly confirms what was captured, à la the
/// built-in macOS screenshot thumbnail. Click it to open the saved file.
final class CapturePreviewPanel: NSPanel, NSTextFieldDelegate {
    private let imageView: NSImageView
    private let nameField: NSTextField
    private var dismissWorkItem: DispatchWorkItem?
    private var fileURL: URL?
    private var userIsEditing = false

    override var canBecomeKey: Bool { true }

    init() {
        let imageSize = NSSize(width: 128, height: 128)
        let panelSize = NSSize(width: 128, height: 154)
        imageView = NSImageView(frame: NSRect(x: 0, y: 26, width: imageSize.width, height: imageSize.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown

        nameField = NSTextField(frame: NSRect(x: 4, y: 3, width: panelSize.width - 8, height: 20))
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 11, weight: .medium)
        nameField.textColor = .white
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.focusRingType = .none
        nameField.toolTip = "Click to rename"

        super.init(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        container.addSubview(imageView)
        container.addSubview(nameField)
        contentView = container

        nameField.delegate = self
        let click = NSClickGestureRecognizer(target: self, action: #selector(openFile))
        imageView.addGestureRecognizer(click)
    }

    func show(image: NSImage, fileURL: URL, on screen: NSScreen) {
        dismissWorkItem?.cancel()
        userIsEditing = false
        self.fileURL = fileURL
        imageView.image = image
        nameField.stringValue = fileURL.lastPathComponent

        setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                y: screen.visibleFrame.midY - frame.height / 2))
        alphaValue = 0
        orderFrontRegardless()
        animator().alphaValue = 1

        scheduleDismiss(after: 5)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    // MARK: - Rename

    func controlTextDidChange(_ obj: Notification) {
        // Only pause auto-dismiss once the user actually starts typing a new name.
        userIsEditing = true
        dismissWorkItem?.cancel()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if userIsEditing {
            commitRename()
            userIsEditing = false
        }
        scheduleDismiss(after: 2)
    }

    private func commitRename() {
        guard let fileURL else { return }
        var newName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != fileURL.lastPathComponent else {
            nameField.stringValue = fileURL.lastPathComponent
            return
        }
        if (newName as NSString).pathExtension.isEmpty {
            newName += "." + fileURL.pathExtension
        }
        let destination = fileURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            self.fileURL = destination
            nameField.stringValue = destination.lastPathComponent
        } catch {
            nameField.stringValue = fileURL.lastPathComponent
            NSSound.beep()
        }
    }

    private func dismiss() {
        // Never dismiss while the user is actively renaming.
        if userIsEditing {
            scheduleDismiss(after: 3)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }

    @objc private func openFile() {
        dismissWorkItem?.cancel()
        if let fileURL, let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([fileURL], withApplicationAt: preview, configuration: config)
        } else if let fileURL {
            NSWorkspace.shared.open(fileURL)
        }
        orderOut(nil)
    }
}
