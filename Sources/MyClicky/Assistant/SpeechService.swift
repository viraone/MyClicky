import AVFoundation
import OSLog
import Speech

private let log = Logger(subsystem: "com.myclicky", category: "speech")

/// On-device speech-to-text using Apple's Speech framework.
///
/// Apple's recognizer finalizes and ends its task after a pause in speech (and
/// after ~1 minute regardless). To support open-ended dictation, finalized
/// segments are accumulated and a fresh recognition task is started on the
/// same audio stream, so the transcript keeps growing until `finish()`.
@MainActor
final class SpeechService {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private let requestBox = RequestBox()
    private var task: SFSpeechRecognitionTask?
    /// Text from recognition tasks that have already finalized.
    private var committed = ""
    /// Partial text from the recognition task currently running.
    private var current = ""
    private var recording = false
    private(set) var latestTranscript = ""

    var onPartial: ((String) -> Void)?

    static func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        stop()
        latestTranscript = ""
        committed = ""
        current = ""

        guard let recognizer, recognizer.isAvailable else {
            throw ServiceError.recognizerUnavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ServiceError.noMicrophone }
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.current?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        recording = true
        startRecognitionTask()
    }

    private func startRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        requestBox.current = request
        current = ""
        log.notice("starting recognition task")

        var newTask: SFSpeechRecognitionTask?
        newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.task === newTask else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    log.debug("partial final=\(result.isFinal) chars=\(text.count)")
                    // After a pause the recognizer may silently restart its
                    // transcription (the new text no longer builds on the old
                    // one). Keep the earlier utterance instead of dropping it.
                    if Self.looksLikeReset(previous: self.current, new: text) {
                        log.notice("reset detected; committing previous utterance")
                        self.commitCurrent()
                    }
                    self.current = text
                    self.publish()
                }
                if let error { log.notice("task error: \(error.localizedDescription, privacy: .public)") }
                // The recognizer ends its task after a pause; fold the segment
                // into `committed` and keep listening with a fresh task.
                if result?.isFinal == true || error != nil {
                    self.commitCurrent()
                    if self.recording {
                        self.startRecognitionTask()
                    }
                }
            }
        }
        task = newTask
    }

    /// A partial that shrinks dramatically and doesn't share its opening words
    /// with the previous partial is a new utterance, not a revision.
    private static func looksLikeReset(previous: String, new: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prev.count >= 12, next.count < prev.count / 2 else { return false }
        let prevWords = prev.lowercased().split(separator: " ")
        let nextWords = next.lowercased().split(separator: " ")
        guard let firstPrev = prevWords.first, let firstNext = nextWords.first else { return !next.isEmpty }
        return firstPrev != firstNext
    }

    private func commitCurrent() {
        log.debug("commit current=\(self.current.count) chars, committed=\(self.committed.count) chars")
        let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !segment.isEmpty {
            committed = committed.isEmpty ? segment : committed + " " + segment
        }
        current = ""
        publish()
    }

    private func publish() {
        let segment = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if committed.isEmpty { text = segment }
        else if segment.isEmpty { text = committed }
        else { text = committed + " " + segment }
        latestTranscript = text
        onPartial?(text)
    }

    /// Stops capturing and returns the best transcript, allowing a short
    /// grace period for the recognizer to finalize.
    func finish() async -> String {
        recording = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        requestBox.current?.endAudio()
        try? await Task.sleep(nanoseconds: 800_000_000)
        commitCurrent()
        let text = latestTranscript
        log.notice("finish -> \(text.count) chars")
        stop()
        return text
    }

    func stop() {
        recording = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        task?.cancel()
        task = nil
        requestBox.current = nil
    }

    /// Thread-safe holder so the audio tap always feeds the active request.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SFSpeechAudioBufferRecognitionRequest?
        var current: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    enum ServiceError: LocalizedError {
        case recognizerUnavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: "Speech recognition is unavailable."
            case .noMicrophone: "No microphone input is available."
            }
        }
    }
}
