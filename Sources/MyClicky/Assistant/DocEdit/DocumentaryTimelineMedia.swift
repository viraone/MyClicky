import AVFoundation
import CoreGraphics
import Foundation

enum DocumentaryTimelineMedia {
    /// Pure. Splits samples into `buckets` consecutive groups; group i covers indices (i*n/buckets) ..< ((i+1)*n/buckets) using integer division (n = samples.count). Each bucket's value is the largest abs(Int(sample)) in it (0 for an empty group). Then every value is divided by the largest bucket value, so the loudest bucket is exactly 1. Returns [] when samples is empty or buckets <= 0. When every sample is 0 it returns `buckets` zeros.
    static func normalizedPeaks(samples: [Int16], buckets: Int) -> [Float] {
        guard !samples.isEmpty, buckets > 0 else { return [] }
        let n = samples.count
        var peaks = [Float](repeating: 0, count: buckets)
        for i in 0..<buckets {
            let start = (i * n) / buckets
            let end = ((i + 1) * n) / buckets
            guard start < end else { continue }
            var maxAbs: Int = 0
            for j in start..<end {
                let value = abs(Int(samples[j]))
                if value > maxAbs { maxAbs = value }
            }
            peaks[i] = Float(maxAbs)
        }
        guard let largest = peaks.max(), largest > 0 else { return peaks }
        return peaks.map { $0 / largest }
    }

    /// Pure. Centres of `count` equal segments: duration * (Double(i) + 0.5) / Double(count) for i in 0..<count. Returns [] when duration <= 0 or count <= 0.
    static func thumbnailTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }

    /// Reads the first audio track of the file as 16-bit mono PCM at 8000 Hz and returns normalizedPeaks of all samples with the given bucket count. Returns [] on any failure (no audio track, reader error). Never throws.
    static func waveformPeaks(url: URL, buckets: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return [] }
        var allSamples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(dataBuffer)
            var samples = [Int16](repeating: 0, count: length / 2)
            samples.withUnsafeMutableBytes { rawBuffer in
                CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: rawBuffer.baseAddress!)
            }
            allSamples.append(contentsOf: samples)
        }
        if reader.status == .failed { return [] }
        return normalizedPeaks(samples: allSamples, buckets: buckets)
    }

    /// Returns up to `count` frames of the first video track, evenly spread (times from thumbnailTimes), each at most `maxHeight` pixels tall. Returns [] on any failure. Never throws.
    static func thumbnails(url: URL, count: Int, maxHeight: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), CMTimeGetSeconds(duration) > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxHeight * 4, height: maxHeight)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var images: [CGImage] = []
        for t in thumbnailTimes(duration: CMTimeGetSeconds(duration), count: count) {
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                images.append(result.image)
            }
        }
        return images
    }
}
