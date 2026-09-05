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
    /// True once `stop()` has been called — the current segment should
    /// finalize instead of rolling into a new one, and we stop streaming
    /// partials to the Mac.
    private var stopping = false
    /// Resolved when the segment `stop()` is waiting on actually finalizes,
    /// so `stop()` can wait for the real event instead of a fixed delay.
    private var finalizeContinuation: CheckedContinuation<Void, Never>?
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
        stopping = false
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
                guard let self else { return }
                if let result {
                    let updated = result.bestTranscription.formattedString
                    // On-device recognition does not reliably report isFinal
                    // after a pause — it sometimes restarts its own
                    // transcription instead, and the next result is a fresh
                    // phrase rather than a longer version of the last one.
                    // Relying on isFinal alone silently loses everything said
                    // before the pause (observed: a three-part command
                    // arrived as only its last part). So bank the old text
                    // whenever the new text stops extending it.
                    if !self.current.isEmpty, Self.isRestart(from: self.current, to: updated) {
                        self.commitCurrent()
                    }
                    self.current = updated
                    // Once stopping, the phone is showing its final answer,
                    // not live partials — stop pushing updates to the Mac.
                    if !self.stopping { self.publish() }
                    if result.isFinal { self.rollSegment() }
                } else if error != nil {
                    self.commitCurrent()
                    self.resolveFinalize()
                }
            }
        }
    }

    /// Whether the recognizer threw away what it had and started a new phrase,
    /// as opposed to revising the one it was already working on.
    ///
    /// Compares which words survive, not a common prefix. The recognizer
    /// rewrites words anywhere in the phrase — "David Babu" became "David
    /// Bapu" and back again — and one changed word near the front destroys a
    /// prefix comparison while leaving nearly every word untouched. That read
    /// as a restart and banked the same sentence three times. A revision keeps
    /// most of its words; a genuine restart keeps almost none.
    private static func isRestart(from previous: String, to updated: String) -> Bool {
        let old = words(previous)
        guard !old.isEmpty else { return false }
        let new = Set(words(updated))
        let kept = old.filter(new.contains).count
        return kept * 5 < old.count * 2      // fewer than 40% survived
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func commitCurrent() {
        if !current.isEmpty {
            committed = (committed + " " + current).trimmingCharacters(in: .whitespaces)
            current = ""
        }
    }

    /// A segment just finalized (iOS does this after a pause, or because
    /// `stop()` called `endAudio()`). Bank its text; while still recording,
    /// immediately start a fresh segment so nothing is lost between them.
    /// While stopping, this final segment IS the answer `stop()` is waiting
    /// on — signal it instead of starting another.
    private func rollSegment() {
        commitCurrent()
        if stopping {
            resolveFinalize()
        } else {
            startSegment()
        }
    }

    private func resolveFinalize() {
        guard let pending = finalizeContinuation else { return }
        finalizeContinuation = nil
        pending.resume()
    }

    private func publish() {
        transcript = (committed + " " + current).trimmingCharacters(in: .whitespaces)
        onPartial?(transcript)
    }

    /// Stops recording and returns the final transcript. Waits for the
    /// recognizer to actually finalize the last segment rather than a fixed
    /// delay — on-device recognition time varies with sentence length and
    /// device load, and a too-short fixed wait was silently dropping the
    /// tail end of longer utterances (the finalize callback arrived after
    /// `isListening` had already gone false and was discarded).
    func stop() async -> String {
        stopping = true
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        level = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalizeContinuation = continuation
            // Safety net only — normally `rollSegment`/the error branch
            // resolves this well before 3s once the real result lands.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.resolveFinalize()
            }
        }

        isListening = false
        stopping = false
        task?.finish()
        audioEngine = nil
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = (committed + " " + current).trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript
    }
}
