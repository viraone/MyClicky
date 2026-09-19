import Foundation
import Speech

/// Transcribes a video or audio file with word timings, on-device when the
/// Mac can — that's what lifts Apple's one-minute limit on server
/// recognition, and a talking-head take is often longer than that.
enum VideoTranscriber {
    enum Failure: LocalizedError {
        case notAuthorized
        case unavailable
        case recognizer(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition isn't allowed — turn it on for Peeky in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: "Speech recognition isn't available right now."
            case .recognizer(let message): message
            }
        }
    }

    /// Every locale the recogniser can listen in, by name — the list behind
    /// "What language is being spoken?".
    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { a, b in
            let an = SubtitleLanguages.name(of: a), bn = SubtitleLanguages.name(of: b)
            if an != bn { return an.localizedCaseInsensitiveCompare(bn) == .orderedAscending }
            return a.identifier < b.identifier
        }
    }

    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    /// How far a transcription has got: the last second of the file that
    /// has been heard, and the most recent words, for showing live.
    struct Progress: Sendable {
        var secondsHeard: Double
        var latestText: String
    }

    /// Every word heard in the file, in file seconds. `progress` is called
    /// on the main actor as the recogniser works through the file, and
    /// cancelling the calling task stops the recogniser.
    static func words(in url: URL, locale: Locale = Locale(identifier: "en-US"),
                      progress: (@MainActor @Sendable (Progress) -> Void)? = nil) async throws -> [SpokenWord] {
        guard await requestAuthorization() else { throw Failure.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Partial results are how we know how far through the file it is.
        request.shouldReportPartialResults = progress != nil
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(macOS 13, *) { request.addsPunctuation = true }

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                var finished = false
                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    // A cancelled task can come back as an error *or* as a
                    // "final" result holding whatever it had; neither is a
                    // transcript.
                    if box.cancelled {
                        finished = true
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if let result {
                        let segments = result.bestTranscription.segments
                        if result.isFinal {
                            finished = true
                            cont.resume(returning: segments.map {
                                SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                            })
                        } else if let progress, let last = segments.last {
                            let heard = last.timestamp + last.duration
                            let tail = segments.suffix(12).map(\.substring).joined(separator: " ")
                            Task { @MainActor in progress(Progress(secondsHeard: heard, latestText: tail)) }
                        }
                    } else if let error {
                        finished = true
                        let ns = error as NSError
                        if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                            // Silence comes back as an error; that's an empty transcript, not a failure.
                            cont.resume(returning: [])
                        } else {
                            cont.resume(throwing: Failure.recognizer(error.localizedDescription))
                        }
                    }
                }
                box.task = task
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Holds the recogniser's task so a Swift cancellation can reach it.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _task: SFSpeechRecognitionTask?
        private var _cancelled = false
        var task: SFSpeechRecognitionTask? {
            get { lock.withLock { _task } }
            set { lock.withLock { _task = newValue; if _cancelled { newValue?.cancel() } } }
        }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true; _task?.cancel() } }
    }
}
