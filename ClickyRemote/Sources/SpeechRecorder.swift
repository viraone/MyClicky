import Foundation
import AVFoundation
import Speech

/// On-device speech-to-text using the iPhone microphone.
@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""
    /// Rough mic level (0–1) for the waveform animation.
    @Published var level: CGFloat = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Text from earlier recognition segments. iOS finalizes a segment after
    /// a pause, so we keep what it committed and start a fresh segment.
    private var committed = ""
    private var current = ""
    /// Called on every transcript update (used to stream words to the Mac).
    var onPartial: ((String) -> Void)?

    static func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        transcript = ""
        committed = ""
        current = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Compute a simple RMS level for the waveform.
            var level: CGFloat = 0
            if let data = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { sum += data[i] * data[i] }
                let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
                level = CGFloat(min(1, rms * 12))
            }
            Task { @MainActor in
                guard let self else { return }
                self.request?.append(buffer)
                self.level = level
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isListening = true
        startSegment()
    }

    /// Begins a recognition segment. When iOS finalizes it (after a pause) we
    /// bank the text and immediately start another so nothing is lost.
    private func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let result {
                    self.current = result.bestTranscription.formattedString
                    self.publish()
                    if result.isFinal { self.rollSegment() }
                } else if error != nil {
                    self.rollSegment()
                }
            }
        }
    }

    private func rollSegment() {
        guard isListening else { return }
        if !current.isEmpty {
            committed = (committed + " " + current).trimmingCharacters(in: .whitespaces)
            current = ""
        }
        startSegment()
    }

    private func publish() {
        transcript = (committed + " " + current).trimmingCharacters(in: .whitespaces)
        onPartial?(transcript)
    }

    /// Stops recording and returns the final transcript.
    func stop() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        level = 0
        // Give the recognizer a moment to finalize the last segment.
        try? await Task.sleep(nanoseconds: 500_000_000)
        isListening = false
        task?.finish()
        audioEngine = nil
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = (committed + " " + current).trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript
    }
}
