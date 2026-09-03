import SwiftUI
import AppKit

@main
struct MyClickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CaptureController?
    private var assistant: AssistantController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = CaptureController()
        controller?.start()
        assistant = AssistantController()
        assistant?.start()
        // Route ⌃⌥X captures into the panel's Capture + Dictate tab, and let
        // the iOS remote's "5" key start a capture.
        controller?.onCaptured = { [weak self] image, url in
            self?.assistant?.showCapture(image: image, url: url)
        }
        assistant?.onCaptureRequest = { [weak self] in
            self?.controller?.trigger()
        }
    }
}
