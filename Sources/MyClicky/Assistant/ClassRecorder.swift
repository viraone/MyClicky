import AVFoundation
import AppKit
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.myclicky", category: "class-recorder")

/// Records whatever the Mac's current input hears (the wireless-mic receiver
/// plugged into the Mac) to an .m4a in Desktop/Class Recordings. The phone's
/// CLASS tab only starts and stops it; the audio never leaves the Mac.
///
/// Lines sent back to the phone (see RemoteControlService):
///   CLASSREC_STATE RECORDING\t<input device>
///   CLASSREC_STATE IDLE\t<input device>\t<last saved file name, or empty>
///   CLASSREC_STATE FAIL\t<message>
///   CLASSREC_LEVEL <0-100>\t<elapsed seconds>      (about five times a second)
@MainActor
final class ClassRecorder {
    /// Sends one line to the phone(s).
    var send: (String) -> Void = { _ in }
    /// Shows a toast on the Mac.
    var toast: (String, Bool) -> Void = { _, _ in }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var lastFileName = ""
    private var quitObserver: NSObjectProtocol?

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// What a freshly connected phone should see.
    func stateLine() -> String {
        if isRecording { return "CLASSREC_STATE RECORDING\t\(Self.inputDeviceName())" }
        return "CLASSREC_STATE IDLE\t\(Self.inputDeviceName())\t\(lastFileName)"
    }

    func handle(_ command: String) {
        switch command.trimmingCharacters(in: .whitespaces).uppercased() {
        case "START": start()
        case "STOP": stop()
        default: send(stateLine())
        }
    }

    func start() {
        guard !isRecording else { send(stateLine()); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.begin() } else { self.fail("Mic access is off. Allow it in System Settings, Privacy & Security, Microphone.") }
                }
            }
        default:
            fail("Mic access is off. Allow it in System Settings, Privacy & Security, Microphone.")
        }
    }

    private func begin() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Class Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail("Couldn't make the Class Recordings folder on the Desktop.")
            return
        }
        let stamp = Self.fileStamp(Date())
        let url = folder.appendingPathComponent("Class \(stamp).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                fail("The Mac wouldn't start recording. Check the mic is the Mac's input in System Settings, Sound.")
                return
            }
            recorder = r
        } catch {
            fail("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        startedAt = Date()
        lastFileName = url.lastPathComponent
        send(stateLine())
        toast("Recording the class mic", true)
        log.info("recording to \(url.path, privacy: .public)")

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A quit mid-recording must still close the file, or the .m4a is unreadable.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        // Average power runs from -60 dB (silence) to 0 dB (clipping).
        let db = max(-60, min(0, r.averagePower(forChannel: 0)))
        let percent = Int(((db + 60) / 60 * 100).rounded())
        let elapsed = Int(Date().timeIntervalSince(startedAt ?? Date()))
        send("CLASSREC_LEVEL \(percent)\t\(elapsed)")
    }

    func stop() {
        guard let r = recorder else { send(stateLine()); return }
        r.stop()
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
        startedAt = nil
        send(stateLine())
        toast("Saved \(lastFileName) (\(seconds / 60):\(String(format: "%02d", seconds % 60)))", true)
    }

    private func fail(_ message: String) {
        send("CLASSREC_STATE FAIL\t\(message)")
        toast(message, false)
    }

    // MARK: - Helpers

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd h.mm.ss a"
        return f.string(from: date)
    }

    /// The name of the Mac's current default input, e.g. "MacBook Pro Microphone"
    /// or "USB Audio Device". Shown on the phone so you can see the mic is live.
    static func inputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return "No input found" }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let name else { return "Unknown input" }
        return name.takeRetainedValue() as String
    }
}
