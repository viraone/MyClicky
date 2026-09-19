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

    /// Every word heard in the file, in file seconds.
    static func words(in url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> [SpokenWord] {
        guard await requestAuthorization() else { throw Failure.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw Failure.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(macOS 13, *) { request.addsPunctuation = true }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.segments.map {
                        SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                } else if let error {
                    finished = true
                    // Silence comes back as an error; that's an empty transcript, not a failure.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        cont.resume(returning: [])
                    } else {
                        cont.resume(throwing: Failure.recognizer(error.localizedDescription))
                    }
                }
                _ = task
            }
        }
    }
}
