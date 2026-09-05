import AppKit
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "photosave")

/// Saves a photo sent from the phone straight into Desktop/VIRADETH_RESUME —
/// a one-tap replacement for "save to Photos, send to a WhatsApp group,
/// switch to the Mac, open WhatsApp, download the attachment".
enum PhotoSaveActions {
    private static let folderName = "VIRADETH_RESUME"

    @MainActor
    static func save(_ imageData: Data, status: @escaping (_ message: String, _ ok: Bool) -> Void) {
        ActivityLog.recordAction("save-photo-to-desktop", ["bytes": "\(imageData.count)"])
        log.notice("save \(imageData.count) bytes")
        guard NSImage(data: imageData) != nil else {
            status("That photo couldn't be decoded.", false)
            return
        }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            status("Couldn't find your Desktop folder.", false)
            return
        }
        let folder = desktop.appendingPathComponent(folderName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error("couldn't create \(folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status("Couldn't create the \(folderName) folder: \(error.localizedDescription)", false)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let name = "Photo from phone \(formatter.string(from: Date())).jpg"
        let url = folder.appendingPathComponent(name)
        do {
            try imageData.write(to: url)
            log.notice("saved to \(url.path, privacy: .public)")
            status("Saved to \(folderName) — \(name)", true)
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
            status("Couldn't save to \(folderName): \(error.localizedDescription)", false)
        }
    }
}
