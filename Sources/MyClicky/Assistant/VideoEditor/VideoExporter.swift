import AppKit
import AVFoundation
import QuartzCore

/// Turns a `VideoProject` into an AVFoundation composition — for the preview
/// player and for the exported file — and writes the finished MP4.
enum VideoExporter {
    /// The Reels frame — what a project renders at unless it picks another
    /// `FrameFormat`. The default for every helper that takes a `render`.
    static let renderSize = FrameFormat.default.renderSize
    static let frameRate: Int32 = 30
    static let timescale: CMTimeScale = 600

    enum Failure: LocalizedError {
        case noVideo
        case noClips
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo: "Couldn't set up the video track."
            case .noClips: "Add a clip first."
            case .exportFailed(let message): "Export failed: \(message)"
            case .cancelled: "Export cancelled."
            }
        }
    }

    struct Timeline {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
    }

    /// The transform that shows a whole source frame inside the render
    /// frame — scaled to fit, centred, bars where the shapes differ. A 9:16
    /// phone take fills the frame exactly; a widescreen screen recording
    /// sits letterboxed in the middle.
    /// `zoom` scales around the centre on top of that: 1 is the fit,
    /// larger crops in — how a landscape clip is made to fill 9:16. `pan`
    /// then moves the picture anywhere, as a share of the frame (right and
    /// down positive), like dragging the video about VEED's canvas; only
    /// its centre is kept inside the frame so it can't be lost.
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, zoom: CGFloat = 1,
                             pan: CGSize = .zero, into render: CGSize = renderSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return .identity }
        let scale = min(render.width / width, render.height / height) * max(0.1, zoom)
        let dx = clampPan(pan.width) * render.width
        let dy = clampPan(pan.height) * render.height
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - width * scale) / 2 + dx,
                                             y: (render.height - height * scale) / 2 + dy))
    }

    /// How far the picture may be moved each way: half the frame, so its
    /// centre never leaves the frame.
    static let maxPan: CGFloat = 0.5

    static func clampPan(_ share: CGFloat) -> CGFloat { min(max(-maxPan, share), maxPan) }

    /// The zoom at which a clip just covers the frame — no black bars.
    static func fillZoom(naturalSize: CGSize, preferredTransform: CGAffineTransform, into render: CGSize = renderSize) -> Double {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return 1 }
        let fit = min(render.width / width, render.height / height)
        let fill = max(render.width / width, render.height / height)
        return Double(fill / fit)
    }

    /// The clips laid end to end, each framed for the project's format. No
    /// captions: those are drawn by the preview itself, and burned in only
    /// on export.
    /// `zoomed` false leaves every clip at the fit; the preview zooms live
    /// on its own layer instead, so a zoom never rebuilds the player.
    static func build(_ project: VideoProject, zoomed: Bool = true) async throws -> Timeline {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideo
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let render = project.renderSize
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for clip in project.clips where clip.duration > 0 {
            let asset = AVURLAsset(url: clip.source)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (natural, preferred, trackRange) = try await source.load(.naturalSize, .preferredTransform, .timeRange)
            let wanted = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: timescale),
                                     duration: CMTime(seconds: clip.duration, preferredTimescale: timescale))
            let range = wanted.intersection(trackRange)
            guard range.duration > .zero else { continue }
            try videoTrack.insertTimeRange(range, of: source, at: cursor)
            if let audioTrack, let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = wanted.intersection(try await audio.load(.timeRange))
                if audioRange.duration > .zero {
                    try audioTrack.insertTimeRange(audioRange, of: audio, at: cursor)
                }
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fitTransform(naturalSize: natural, preferredTransform: preferred,
                                            zoom: zoomed ? CGFloat(clip.zoom) : 1,
                                            pan: zoomed ? CGSize(width: clip.panX, height: clip.panY) : .zero,
                                            into: render), at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + range.duration
        }
        guard !instructions.isEmpty else { throw Failure.noClips }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = render
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions
        return Timeline(composition: composition, videoComposition: videoComposition)
    }

    // MARK: Captions

    /// The pill a caption sits in, and where, for a frame of `render`.
    /// `text` is taken as already spelled by the style. With an `anchor`
    /// the pill is centred there (kept inside the frame); without one it
    /// sits where the style puts it.
    static func captionFrame(for text: String, style: CaptionStyle, anchor: CaptionAnchor? = nil,
                             render: CGSize = renderSize) -> (pill: CGRect, textSize: CGSize) {
        let inset = style.strokeColor == nil ? 0 : style.strokeWidth
        let maxWidth = render.width * style.maxWidthShare - style.horizontalPadding * 2 - inset * 2
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textSize = CGSize(width: ceil(bounds.width) + inset * 2, height: ceil(bounds.height) + inset * 2)
        let pillSize = CGSize(width: textSize.width + style.horizontalPadding * 2,
                              height: textSize.height + style.verticalPadding * 2)
        let centre = anchor.map { CGPoint(x: render.width * $0.x, y: render.height * $0.y) }
            ?? CGPoint(x: render.width / 2, y: render.height * style.centreFromBottom)
        let pill = CGRect(x: min(max(0, centre.x - pillSize.width / 2), max(0, render.width - pillSize.width)),
                          y: min(max(0, centre.y - pillSize.height / 2), max(0, render.height - pillSize.height)),
                          width: pillSize.width, height: pillSize.height)
        return (pill.integral, textSize)
    }

    /// One caption drawn in `style` at its place in a `render`-sized frame:
    /// the box (if any), an outline behind the letters (if any), the letters,
    /// with the `highlight`-th word of the first line in the accent colour.
    /// The same layer serves the export, the preview and the style tiles.
    @MainActor
    static func captionLayer(text raw: String, highlight: Int? = nil, style: CaptionStyle, anchor: CaptionAnchor? = nil,
                             render: CGSize = renderSize) -> CALayer {
        let shown = style.display(raw)
        let (pill, textSize) = captionFrame(for: shown, style: style, anchor: anchor, render: render)
        let container = CALayer()
        container.frame = pill
        container.backgroundColor = (style.pillColor ?? .clear).cgColor
        container.cornerRadius = style.cornerRadius
        container.masksToBounds = false

        let textFrame = CGRect(x: (pill.width - textSize.width) / 2,
                               y: (pill.height - textSize.height) / 2,
                               width: textSize.width, height: textSize.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var fill: [NSAttributedString.Key: Any] = [
            .font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph,
        ]
        let inset = style.strokeColor == nil ? 0 : style.strokeWidth
        // A stroke centred on the outline would eat into the letters, so
        // outlines are their own layer underneath, stroke only.
        var backmost: CALayer?
        if let strokeColor = style.strokeColor, style.strokeWidth > 0 {
            var outline = fill
            outline[.strokeColor] = strokeColor
            outline[.strokeWidth] = style.strokeWidth * 2 / style.fontSize * 100
            let layer = textLayer(shown, attributes: outline, frame: textFrame.insetBy(dx: inset, dy: inset))
            container.addSublayer(layer)
            backmost = layer
        }
        let letters = NSMutableAttributedString(string: shown, attributes: fill)
        if let highlight, let accent = style.accentColor,
           let range = wordRanges(in: shown).dropFirst(highlight).first {
            letters.addAttribute(.foregroundColor, value: accent, range: range)
        }
        let face = textLayer(letters, frame: textFrame.insetBy(dx: inset, dy: inset))
        container.addSublayer(face)
        if let shadowColor = style.shadowColor {
            let target = backmost ?? face
            target.shadowColor = shadowColor.cgColor
            target.shadowOpacity = 1
            target.shadowRadius = style.shadowRadius
            target.shadowOffset = style.shadowOffset
        }
        return container
    }

    private static func textLayer(_ text: String, attributes: [NSAttributedString.Key: Any], frame: CGRect) -> CATextLayer {
        textLayer(NSAttributedString(string: text, attributes: attributes), frame: frame)
    }

    private static func textLayer(_ text: NSAttributedString, frame: CGRect) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text
        layer.alignmentMode = .center
        layer.isWrapped = true
        layer.contentsScale = 2
        layer.masksToBounds = false
        layer.frame = frame
        return layer
    }

    /// Where each word of the first line sits in `text`, split on spaces
    /// so contractions stay whole.
    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let firstLine = ns.range(of: "\n").location
        var ranges: [NSRange] = []
        var index = 0
        let limit = firstLine == NSNotFound ? ns.length : firstLine
        while index < limit {
            while index < limit, ns.character(at: index) == 0x20 { index += 1 }
            let start = index
            while index < limit, ns.character(at: index) != 0x20 { index += 1 }
            if index > start { ranges.append(NSRange(location: start, length: index - start)) }
        }
        return ranges
    }

    /// A layer per caption, each visible only for its own stretch of the
    /// video — or one per *word* when the style follows the speaker. Core
    /// Animation's timeline is the video's, so a plain opacity animation
    /// with a begin time does the scheduling.
    @MainActor
    static func captionOverlay(for cues: [TimelineCue], style: CaptionStyle, anchor: CaptionAnchor? = nil,
                               render: CGSize = renderSize,
                               wordStarts: (TimelineCue) -> [Double] = { _ in [] }) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: render)
        for cue in cues where !cue.text.trimmingCharacters(in: .whitespaces).isEmpty && cue.end > cue.start {
            let shown = cue.displayText
            var stretches: [(highlight: Int?, start: Double, end: Double)] = [(nil, cue.start, cue.end)]
            if style.accentColor != nil {
                let starts = wordStarts(cue).filter { $0 >= cue.start && $0 < cue.end }
                if !starts.isEmpty {
                    stretches = starts.indices.map { i in
                        (i, i == 0 ? cue.start : starts[i], i + 1 < starts.count ? starts[i + 1] : cue.end)
                    }
                }
            }
            for stretch in stretches where stretch.end > stretch.start {
                let container = captionLayer(text: shown, highlight: stretch.highlight, style: style,
                                             anchor: cue.anchor ?? anchor, render: render)
                container.opacity = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 1
                show.toValue = 1
                show.beginTime = stretch.start <= 0 ? AVCoreAnimationBeginTimeAtZero : stretch.start
                show.duration = stretch.end - stretch.start
                show.isRemovedOnCompletion = false
                container.add(show, forKey: "visible")
                overlay.addSublayer(container)
            }
        }
        return overlay
    }

    // MARK: Export

    /// Writes the project as an H.264 MP4 at its format's size, captions
    /// burned in. `progress` is called on the main actor with 0…1.
    @MainActor
    static func export(_ project: VideoProject, style: CaptionStyle, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let timeline = try await build(project)
        let render = project.renderSize

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: render)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(captionOverlay(for: project.timelineCues, style: style, anchor: project.captionAnchor,
                                          render: render) { project.wordStarts(for: $0) })
        timeline.videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: timeline.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed("no export session")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = timeline.videoComposition
        session.shouldOptimizeForNetworkUse = true

        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await session.export()
        poll.cancel()
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw Failure.cancelled
        default:
            throw Failure.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }
}
