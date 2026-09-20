import AVFoundation
import CoreGraphics

/// Small frames from a clip, about one a second: the filmstrip iMovie
/// draws along the top of a clip so you can see what's where before you
/// cut. Generated once per source and kept in memory for the session.
enum Filmstrip {
    @MainActor
    static func frames(for url: URL) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }
        let count = max(6, min(150, Int(duration.rounded(.up))))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        // A nearby keyframe is fine for a thumbnail; exact frames cost
        // seconds per clip.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let times = (0..<count).map {
            CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
        }
        var frames: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { frames.append(image) }
        }
        return frames
    }

    /// The frame nearest `time` seconds into the source.
    static func frame(in frames: [CGImage], at time: Double, sourceDuration: Double) -> CGImage? {
        guard !frames.isEmpty, sourceDuration > 0 else { return nil }
        let index = Int(Double(frames.count) * time / sourceDuration)
        return frames[max(0, min(frames.count - 1, index))]
    }
}
