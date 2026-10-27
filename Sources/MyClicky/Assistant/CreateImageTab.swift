import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The create_image tab: a description typed (or dictated) into the prompt
/// bar becomes a picture drawn on this Mac by mflux's Z-Image Turbo model.
/// Local and free — the description never leaves the machine.
@MainActor
final class CreateImageModel: ObservableObject {
    /// A whole-pixel size, so it compares directly with the model's
    /// multiples of 16.
    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    enum Size: String, CaseIterable, Identifiable {
        case square, wide, tall
        case instagramPost, instagramStory

        var id: String { rawValue }

        /// What the model is asked to draw. Z-Image Turbo only accepts
        /// multiples of 16, which is why Instagram sizes are drawn a little
        /// larger and trimmed afterwards.
        var width: Int {
            switch self {
            case .square: 1024
            case .wide: 1344
            case .tall: 768
            case .instagramPost, .instagramStory: 1088
            }
        }

        var height: Int {
            switch self {
            case .square: 1024
            case .wide: 768
            case .tall: 1344
            case .instagramPost: 1360
            case .instagramStory: 1920
            }
        }

        var drawSize: PixelSize { PixelSize(width: width, height: height) }

        /// The exact size saved to disk, for presets that need a centre
        /// crop after drawing. Nil means the drawn file is the final file.
        var finalSize: PixelSize? {
            switch self {
            case .square, .wide, .tall: nil
            case .instagramPost: PixelSize(width: 1080, height: 1350)
            case .instagramStory: PixelSize(width: 1080, height: 1920)
            }
        }

        var label: String {
            switch self {
            case .square: "Square 1024×1024"
            case .wide: "Wide 1344×768"
            case .tall: "Tall 768×1344"
            case .instagramPost: "Instagram Post"
            case .instagramStory: "Instagram Story"
            }
        }

        var shortLabel: String {
            switch self {
            case .square: "Square"
            case .wide: "Wide"
            case .tall: "Tall"
            case .instagramPost: "Instagram Post"
            case .instagramStory: "Instagram Story"
            }
        }

        var icon: String {
            switch self {
            case .square: "square"
            case .wide: "rectangle"
            case .tall: "rectangle.portrait"
            case .instagramPost: "rectangle.portrait"
            case .instagramStory: "rectangle.portrait"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case drawing
        case done
        case failed(String)
    }

    /// One picture in the strip, or the one shown large. The image is read
    /// once when the folder is scanned rather than on every redraw.
    struct Picture: Identifiable, Equatable {
        let url: URL
        let description: String
        let image: NSImage?
        var id: URL { url }

        static func == (lhs: Picture, rhs: Picture) -> Bool {
            lhs.url == rhs.url && lhs.description == rhs.description
        }
    }

    struct Progress: Equatable {
        let step: Int
        let total: Int
        let downloading: Bool
    }

    @Published var phase: Phase = .idle
    @Published var current: Picture?
    @Published var recent: [Picture] = []
    @Published var activeDescription = ""
    @Published var lastDescription = ""
    @Published var progressStep: Int?
    @Published var progressTotal: Int?
    @Published var downloading = false
    @Published var notice: String?
    @Published var startedAt: Date?

    /// Remembered between launches; Square is the model's native size.
    @Published var size: Size {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: Self.sizeKey) }
    }

    static let sizeKey = "createImageSize"
    static let imagesFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Peeky Images", isDirectory: true)
    static let imagesFolderDisplay = "~/Pictures/Peeky Images"
    static let missingToolMessage =
        "The image tool isn't installed. In Terminal run: brew install uv && uv tool install mflux"
    static let stillDrawingMessage = "Still drawing — press Stop first"

    private var process: Process?
    private var generation = 0
    private var stopped = false
    private var stderrTail = ""
    private var outputURL: URL?
    /// The size the in-flight picture was started with, so changing the
    /// picker mid-draw can't trim it to the wrong aspect ratio.
    private var activeSize: Size = .square

    init() {
        size = Size(rawValue: UserDefaults.standard.string(forKey: Self.sizeKey) ?? "") ?? .square
    }

    // MARK: - Tool and pure helpers

    /// `~/.local/bin` first, then Homebrew's prefix.
    static var toolURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/mflux-generate-z-image-turbo"),
            URL(fileURLWithPath: "/opt/homebrew/bin/mflux-generate-z-image-turbo"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var toolInstalled: Bool { Self.toolURL != nil }

    /// The first six words, lowercased, with everything that isn't a letter,
    /// digit or hyphen folded into a hyphen (runs collapsed, at most 40
    /// characters). An empty or punctuation-only description becomes "image".
    static func slug(from description: String) -> String {
        let words = description.split(whereSeparator: { $0.isWhitespace }).prefix(6)
        var out = ""
        for scalar in words.joined(separator: "-").lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.count > 40 { out = String(out.prefix(40)) }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "image" : out
    }

    /// `yyyy-MM-dd HH.mm.ss <slug>`, in local time the way Finder sorts it.
    static func fileBaseName(for description: String, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(formatter.string(from: date)) \(slug(from: description))"
    }

    /// The `.txt` next to a picture holding the description that made it.
    static func sidecarURL(for image: URL) -> URL {
        image.deletingPathExtension().appendingPathExtension("txt")
    }

    /// The last `N/M` in a chunk of tqdm output, plus whether the chunk says
    /// the model weights are being fetched. `nil` when there is no fraction
    /// to show yet (a bare "Fetching 17 files" line, say).
    static func parseProgress(_ chunk: String) -> Progress? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#) else { return nil }
        let text = chunk as NSString
        let matches = regex.matches(in: chunk, range: NSRange(location: 0, length: text.length))
        guard let last = matches.last, last.numberOfRanges >= 3,
              let step = Int(text.substring(with: last.range(at: 1))),
              let total = Int(text.substring(with: last.range(at: 2))),
              total > 0 else { return nil }
        return Progress(step: step, total: total, downloading: isDownloading(chunk))
    }

    /// Hugging Face's download bars begin with "Fetching" (or "Downloading");
    /// those are the first-run-only weight downloads.
    static func isDownloading(_ chunk: String) -> Bool {
        chunk.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("Fetching") || trimmed.hasPrefix("Downloading")
            }
    }

    /// The centred crop that turns a drawn PNG into the exact Instagram
    /// size, or nil when the drawn size is already final (or too small to
    /// crop). Pure, so the geometry can be tested on its own.
    static func cropRect(drawn: PixelSize, final: PixelSize) -> CGRect? {
        guard drawn != final,
              drawn.width >= final.width,
              drawn.height >= final.height else { return nil }
        return CGRect(
            x: (drawn.width - final.width) / 2,
            y: (drawn.height - final.height) / 2,
            width: final.width,
            height: final.height
        )
    }

    /// Crops the PNG at `url` in place to `rect`, preserving pixels rather
    /// than scaling. Returns false and leaves the original file untouched if
    /// anything goes wrong.
    static func cropPNG(at url: URL, to rect: CGRect) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = image.cropping(to: rect) else { return false }

        // Write beside the original so replaceItemAt stays on one volume.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".peeky-cropping-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    /// Exit code plus the last handful of lines so the panel can say why.
    static func failureMessage(exit: Int32, stderr: String) -> String {
        let lines = stderr.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(6).joined(separator: "\n")
        return tail.isEmpty
            ? "The image tool failed (exit \(exit))."
            : "The image tool failed (exit \(exit)):\n\(tail)"
    }

    // MARK: - Drawing

    func generate(_ description: String) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard phase != .drawing else {
            notice = Self.stillDrawingMessage
            return
        }
        guard let tool = Self.toolURL else {
            phase = .failed(Self.missingToolMessage)
            return
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: Self.imagesFolder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Couldn't create \(Self.imagesFolder.path): \(error.localizedDescription)")
            return
        }

        generation += 1
        let activeGeneration = generation
        activeSize = size
        stopped = false
        stderrTail = ""
        progressStep = nil
        progressTotal = nil
        downloading = false
        notice = nil
        current = nil
        activeDescription = text
        lastDescription = text
        startedAt = Date()

        let output = Self.imagesFolder
            .appendingPathComponent(Self.fileBaseName(for: text) + ".png")
        outputURL = output

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "--prompt", text,
            "--width", "\(size.width)",
            "--height", "\(size.height)",
            "--seed", "\(UInt32.random(in: 0...UInt32.max))",
            "--quantize", "8",
            "--output", output.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = FileManager.default.homeDirectoryForCurrentUser.path
            + "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        process.environment = environment

        // mflux reports step progress on stderr as tqdm, with \r between
        // updates. stdout is folded in too so any error printed there lands
        // in the same tail.
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(chunk, generation: activeGeneration)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.finish(exit: process.terminationStatus, generation: activeGeneration)
            }
        }

        phase = .drawing
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            outputURL = nil
            startedAt = nil
            phase = .failed("Couldn't start the image tool: \(error.localizedDescription)")
        }
    }

    /// Terminates mflux; `finish` deletes the half-written PNG once it exits.
    func stop() {
        guard phase == .drawing else { return }
        notice = "Stopping…"
        guard let process else {
            startedAt = nil
            phase = .idle
            notice = "Stopped. Press Enter to try again."
            return
        }
        stopped = true
        process.terminate()
    }

    private func consume(_ chunk: String, generation activeGeneration: Int) {
        guard activeGeneration == generation, phase == .drawing else { return }
        stderrTail += chunk
        if stderrTail.count > 24_000 { stderrTail = String(stderrTail.suffix(16_000)) }
        // Parse the accumulated tail so a tqdm line split across reads still
        // yields its N/M.
        if let progress = Self.parseProgress(stderrTail) {
            progressStep = progress.step
            progressTotal = progress.total
        }
        if Self.isDownloading(chunk) { downloading = true }
    }

    private func finish(exit: Int32, generation activeGeneration: Int) {
        guard activeGeneration == generation else { return }

        let pipe = process?.standardError as? Pipe
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let rest = pipe?.fileHandleForReading.readDataToEndOfFile(), !rest.isEmpty {
            stderrTail += String(decoding: rest, as: UTF8.self)
        }
        process = nil
        startedAt = nil
        progressStep = nil
        progressTotal = nil
        downloading = false
        let output = outputURL
        outputURL = nil

        if stopped {
            stopped = false
            if let output { try? FileManager.default.removeItem(at: output) }
            current = nil
            phase = .idle
            notice = "Stopped. Press Enter to try again."
            return
        }

        if exit == 0, let output, FileManager.default.fileExists(atPath: output.path) {
            let description = lastDescription

            // Trim to the exact Instagram size before anything reads the
            // file: the preview, the clipboard and Recent all see the crop.
            var cropped = true
            let finalSize = activeSize.finalSize
            if let finalSize {
                cropped = Self.cropRect(drawn: activeSize.drawSize, final: finalSize)
                    .map { Self.cropPNG(at: output, to: $0) } ?? false
            }

            try? description.write(to: Self.sidecarURL(for: output), atomically: true, encoding: .utf8)
            let image = NSImage(contentsOf: output)
            if let image {
                let board = NSPasteboard.general
                board.clearContents()
                board.writeObjects([image])
            }
            current = Picture(url: output, description: description, image: image)
            phase = .done
            var summary = ["Saved to \(Self.imagesFolderDisplay)"]
            if image != nil { summary.append("on your clipboard") }
            if !cropped {
                summary.append("couldn't trim to exact Instagram size")
            } else if let finalSize {
                summary.append("\(finalSize.width)×\(finalSize.height) \(activeSize.shortLabel)")
            }
            notice = summary.joined(separator: " · ")
            refreshRecent()
        } else {
            // A failed run can leave a truncated PNG behind.
            if let output { try? FileManager.default.removeItem(at: output) }
            phase = .failed(Self.failureMessage(exit: exit, stderr: stderrTail))
        }
    }

    // MARK: - Library and actions

    func note(_ message: String) {
        notice = message
    }

    /// Shows a picture from the strip. Ignored while mflux is busy.
    func show(_ picture: Picture) {
        guard phase != .drawing else {
            notice = Self.stillDrawingMessage
            return
        }
        current = picture
        lastDescription = picture.description
        phase = .done
        notice = "Saved in \(Self.imagesFolderDisplay)"
    }

    /// Newest first, at most twelve, with each description read from its
    /// sidecar. Called when the tab appears and after each new picture.
    func refreshRecent() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: Self.imagesFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            recent = []
            return
        }
        recent = entries
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(12)
            .map { url in
                let description = (try? String(contentsOf: Self.sidecarURL(for: url), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Picture(url: url, description: description, image: NSImage(contentsOf: url))
            }
    }

    func copyCurrent() {
        guard let picture = current,
              let image = picture.image ?? NSImage(contentsOf: picture.url) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image])
        notice = "Copied · on your clipboard"
    }

    func revealCurrent() {
        guard let url = current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func again() {
        generate(lastDescription)
    }
}

struct CreateImageView: View {
    @ObservedObject var model: CreateImageModel
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.recent.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                recentStrip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(card)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { model.refreshRecent() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text("create_image")
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 8)
            sizePicker
            Text("runs on this Mac · free — nothing leaves it")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var sizePicker: some View {
        Menu {
            ForEach(CreateImageModel.Size.allCases) { option in
                if option == .instagramPost { Divider() }
                Button {
                    model.size = option
                } label: {
                    if option == model.size {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Label(option.label, systemImage: option.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.size.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(model.size.shortLabel)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.07)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Picture size")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.toolInstalled {
            installNotice
        } else {
            switch model.phase {
            case .drawing:
                drawingView
            case .failed(let message):
                failedView(message)
            default:
                if let picture = model.current {
                    doneView(picture)
                } else {
                    emptyHint
                }
            }
        }
    }

    private var emptyHintText: String {
        let base = "Describe a picture below and press Enter. The first one takes longer while the model loads."
        return model.size == .instagramStory
            ? base + " (Story size takes about 40 seconds)"
            : base
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text(emptyHintText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var installNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange.opacity(0.8))
            Text(CreateImageModel.missingToolMessage)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var drawingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(model.activeDescription)”")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .textSelection(.enabled)

            if let step = model.progressStep, let total = model.progressTotal {
                ProgressView(value: Double(step), total: Double(total))
                    .tint(accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(accent)
            }

            HStack(spacing: 10) {
                if let step = model.progressStep, let total = model.progressTotal {
                    Text("step \(step) of \(total)")
                } else if model.downloading {
                    Text("Downloading the model (first time only)…")
                } else {
                    Text("Loading the model…")
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(now: context.date))
                }
                stopButton
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.9))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func elapsedText(now: Date) -> String {
        guard let started = model.startedAt else { return "0s elapsed" }
        return "\(max(0, Int(now.timeIntervalSince(started))))s elapsed"
    }

    private var stopButton: some View {
        Button {
            model.stop()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Stop")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.red.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help("Stop drawing and delete the unfinished picture")
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't draw that", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
            ScrollView {
                Text(message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.lastDescription.isEmpty {
                actionButton("Try again", icon: "arrow.clockwise") {
                    model.generate(model.lastDescription)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func doneView(_ picture: CreateImageModel.Picture) -> some View {
        VStack(spacing: 10) {
            Group {
                if let image = picture.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(picture.description.isEmpty
                     ? picture.url.lastPathComponent
                     : "“\(picture.description)”")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    actionButton("Copy", icon: "doc.on.doc", help: "Copy this picture to the clipboard") {
                        model.copyCurrent()
                    }
                    actionButton("Show in Finder", icon: "folder", help: "Show this picture in Finder") {
                        model.revealCurrent()
                    }
                    actionButton("Again", icon: "arrow.clockwise", tinted: true,
                                 help: "Draw the same description again with a new seed") {
                        model.again()
                    }
                    Spacer(minLength: 0)
                }

                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.recent) { picture in
                        Button {
                            model.show(picture)
                        } label: {
                            Group {
                                if let image = picture.image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                            .frame(width: 76, height: 76)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        model.current?.url == picture.url
                                            ? accent
                                            : Color.white.opacity(0.1),
                                        lineWidth: model.current?.url == picture.url ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(picture.description.isEmpty
                              ? picture.url.lastPathComponent
                              : picture.description)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Style helpers

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func actionButton(_ title: String, icon: String, tinted: Bool = false,
                              help: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(tinted ? Color.black.opacity(0.85) : Color.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(tinted ? accent : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }
}
