import AVFoundation
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

    /// Apple's recogniser quietly returns an *empty* transcript for a file
    /// much over two and a half minutes (on-device) or one minute (server),
    /// so a take is heard a minute at a time and the timings stitched back
    /// together. A minute is also a nice unit of progress to watch.
    static let chunkSeconds = 60.0

    /// The stretches a file of `duration` seconds is heard in.
    static func chunkRanges(duration: Double, chunk: Double = chunkSeconds) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var start = 0.0
        while start < duration - 0.05 {
            let end = min(start + chunk, duration)
            ranges.append(start...end)
            start = end
        }
        return ranges
    }

    /// Every word heard in the file, in file seconds. `progress` is called
    /// on the main actor as the recogniser works through the file, and
    /// cancelling the calling task stops the recogniser.
    static func words(in url: URL, locale: Locale = Locale(identifier: "en-US"),
                      progress: (@MainActor @Sendable (Progress) -> Void)? = nil) async throws -> [SpokenWord] {
        // macOS 26's SpeechAnalyzer hears a whole take at once, with word
        // timings that hold up; the older recogniser dropped most of a
        // noisy room. It needs no permission prompt for files.
        if #available(macOS 26, *), let match = await analyzerLocale(for: locale) {
            return try await analyzerWords(in: url, locale: match, progress: progress)
        }
        guard await requestAuthorization() else { throw Failure.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw Failure.unavailable }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return [] }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekyTranscribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var all: [SpokenWord] = []
        for (index, range) in chunkRanges(duration: duration).enumerated() {
            try Task.checkCancellation()
            let chunk = scratch.appendingPathComponent("chunk-\(index).m4a")
            try await exportAudio(of: asset, range: range, to: chunk)
            let offset = range.lowerBound
            let heard = try await recognize(chunk, with: recognizer, partialResults: progress != nil) { text in
                progress?(Progress(secondsHeard: offset, latestText: text))
            }
            all += heard.compactMap { word in
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SpokenWord(text: text, start: word.start + offset, end: word.end + offset)
            }
            if let progress {
                let tail = all.suffix(12).map(\.text).joined(separator: " ")
                await progress(Progress(secondsHeard: range.upperBound, latestText: tail))
            }
        }
        return all
    }

    /// Just the sound of `range`, as a small AAC file the recogniser reads.
    private static func exportAudio(of asset: AVAsset, range: ClosedRange<Double>, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.recognizer("Couldn't read the clip's sound.")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                        end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        try await withTaskCancellationHandler {
            await session.export()
            if session.status == .cancelled { throw CancellationError() }
            if let error = session.error { throw Failure.recognizer("Couldn't read the clip's sound: \(error.localizedDescription)") }
        } onCancel: {
            session.cancelExport()
        }
    }

    /// One recogniser pass over a short file; words are in that file's seconds.
    private static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer, partialResults: Bool,
                                  partial: @escaping @MainActor @Sendable (String) -> Void) async throws -> [SpokenWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = partialResults
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(macOS 13, *) { request.addsPunctuation = true }

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                var finished = false
                // The on-device recogniser works one utterance at a time: it
                // streams untimed guesses (every timestamp 0), then delivers
                // the utterance once with real word timings, then starts the
                // next utterance from scratch. The "final" result only holds
                // the *last* utterance, so every timed result has to be kept.
                var utterances: [Double: [SpokenWord]] = [:]
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
                        if let words = timedWords(segments) {
                            utterances[words[0].start] = words
                        }
                        if result.isFinal {
                            finished = true
                            cont.resume(returning: utterances.sorted { $0.key < $1.key }.flatMap(\.value))
                        } else if partialResults {
                            let tail = segments.suffix(12).map(\.substring).joined(separator: " ")
                            Task { @MainActor in partial(tail) }
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

    /// The segments as words, or nil while the recogniser is still guessing
    /// (it reports every timestamp as 0 until the utterance is settled).
    private static func timedWords(_ segments: [SFTranscriptionSegment]) -> [SpokenWord]? {
        guard segments.contains(where: { $0.timestamp > 0 || $0.duration > 0 }) else { return nil }
        return segments.map { SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration) }
    }

    // MARK: - macOS 26: SpeechAnalyzer

    /// The analyser's locale for what the user picked: the same tag, or
    /// failing that the same language in any region. Nil means it can't
    /// listen in that language and the older recogniser should.
    @available(macOS 26, *)
    static func analyzerLocale(for locale: Locale) async -> Locale? {
        let wanted = locale.identifier(.bcp47).lowercased()
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wanted }) { return exact }
        guard let language = locale.language.languageCode?.identifier.lowercased() else { return nil }
        return supported.first { $0.language.languageCode?.identifier.lowercased() == language }
    }

    /// Every word in the file, in file seconds, from the on-device
    /// analyser. The whole take goes in at once; results stream back a
    /// phrase at a time with a time range on every word.
    @available(macOS 26, *)
    static func analyzerWords(in url: URL, locale: Locale,
                              progress: (@MainActor @Sendable (Progress) -> Void)?) async throws -> [SpokenWord] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekyTranscribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = scratch.appendingPathComponent("take.m4a")
        try await exportAudio(of: asset, range: 0...duration, to: audio)

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The language model is a one-time download the system keeps.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await progress?(Progress(secondsHeard: 0, latestText: "Downloading the \(SubtitleLanguages.name(of: locale)) speech model, once only…"))
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audio)
        let collector = Task { () -> [SpokenWord] in
            var words: [SpokenWord] = []
            for try await result in transcriber.results where result.isFinal {
                let text = result.text
                var heardTo = 0.0
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    // A lone full stop gets a run of its own; only words count.
                    guard piece.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
                    words.append(SpokenWord(text: piece, start: range.start.seconds, end: range.end.seconds))
                    heardTo = max(heardTo, range.end.seconds)
                }
                if let progress {
                    let tail = words.suffix(12).map(\.text).joined(separator: " ")
                    await progress(Progress(secondsHeard: heardTo, latestText: tail))
                }
            }
            return words
        }
        try await withTaskCancellationHandler {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        return try await collector.value
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
