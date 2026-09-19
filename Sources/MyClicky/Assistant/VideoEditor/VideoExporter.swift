import AppKit
import AVFoundation
import QuartzCore

/// How burned-in captions look. One style for the whole project, sized for
/// a 1080×1920 frame and kept clear of the strips TikTok and Instagram
/// cover with their own controls.
struct CaptionStyle: Equatable {
    var fontSize: CGFloat = 64
    var textColor = NSColor.white
    var pillColor = NSColor.black.withAlphaComponent(0.65)
    var cornerRadius: CGFloat = 20
    var horizontalPadding: CGFloat = 32
    var verticalPadding: CGFloat = 18
    /// Widest a caption may be, as a share of the frame width.
    var maxWidthShare: CGFloat = 0.84
    /// Where the caption's centre sits, as a share of the frame height from
    /// the bottom. 0.30 clears the ~350px caption/controls strip at the foot
    /// of a Reel and still reads as "lower third".
    var centreFromBottom: CGFloat = 0.30

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .heavy) }
}

/// Turns a `VideoProject` into an AVFoundation composition — for the preview
/// player and for the exported file — and writes the finished MP4.
enum VideoExporter {
    static let renderSize = CGSize(width: 1080, height: 1920)
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
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, into render: CGSize = renderSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width), height = abs(oriented.height)
        guard width > 0, height > 0 else { return .identity }
        let scale = min(render.width / width, render.height / height)
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - width * scale) / 2,
                                             y: (render.height - height * scale) / 2))
    }

    /// The clips laid end to end, each framed for 1080×1920. No captions:
    /// those are drawn by the preview itself, and burned in only on export.
    static func build(_ project: VideoProject) async throws -> Timeline {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideo
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
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
            layer.setTransform(fitTransform(naturalSize: natural, preferredTransform: preferred), at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + range.duration
        }
        guard !instructions.isEmpty else { throw Failure.noClips }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions
        return Timeline(composition: composition, videoComposition: videoComposition)
    }

    // MARK: Captions

    /// The pill a caption sits in, and where, for a frame of `render`.
    static func captionFrame(for text: String, style: CaptionStyle, render: CGSize = renderSize) -> (pill: CGRect, textSize: CGSize) {
        let maxWidth = render.width * style.maxWidthShare - style.horizontalPadding * 2
        let attributes: [NSAttributedString.Key: Any] = [.font: style.font]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let pillSize = CGSize(width: textSize.width + style.horizontalPadding * 2,
                              height: textSize.height + style.verticalPadding * 2)
        let pill = CGRect(x: (render.width - pillSize.width) / 2,
                          y: render.height * style.centreFromBottom - pillSize.height / 2,
                          width: pillSize.width, height: pillSize.height)
        return (pill.integral, textSize)
    }

    /// A layer per caption, each visible only for its own stretch of the
    /// video. Core Animation's timeline is the video's, so a plain opacity
    /// animation with a begin time does the scheduling.
    @MainActor
    static func captionOverlay(for cues: [TimelineCue], style: CaptionStyle, render: CGSize = renderSize) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: render)
        for cue in cues where !cue.text.trimmingCharacters(in: .whitespaces).isEmpty && cue.end > cue.start {
            let (pill, textSize) = captionFrame(for: cue.text, style: style, render: render)
            let container = CALayer()
            container.frame = pill
            container.backgroundColor = style.pillColor.cgColor
            container.cornerRadius = style.cornerRadius
            container.opacity = 0

            let text = CATextLayer()
            text.string = NSAttributedString(string: cue.text, attributes: [
                .font: style.font,
                .foregroundColor: style.textColor,
            ])
            text.alignmentMode = .center
            text.isWrapped = true
            text.contentsScale = 2
            text.frame = CGRect(x: (pill.width - textSize.width) / 2,
                                y: (pill.height - textSize.height) / 2,
                                width: textSize.width, height: textSize.height)
            container.addSublayer(text)

            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = cue.start <= 0 ? AVCoreAnimationBeginTimeAtZero : cue.start
            show.duration = cue.end - cue.start
            show.isRemovedOnCompletion = false
            container.add(show, forKey: "visible")
            overlay.addSublayer(container)
        }
        return overlay
    }

    // MARK: Export

    /// Writes the project as an H.264 MP4 at 1080×1920, captions burned in.
    /// `progress` is called on the main actor with 0…1.
    @MainActor
    static func export(_ project: VideoProject, style: CaptionStyle, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let timeline = try await build(project)

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(captionOverlay(for: project.timelineCues, style: style))
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
