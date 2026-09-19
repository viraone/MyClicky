import AVFoundation

/// Reads a clip's audio once and boils it down to a few hundred loudness
/// peaks, 0…1, spread evenly across the whole source. That's the picture
/// editors draw inside a clip: spikes where someone talks, flat where it's
/// quiet — so you can see where a clean cut is instead of hunting for it.
enum AudioWaveform {
    /// How many peaks to keep per clip. Enough to show every pause in a
    /// two-minute take at any timeline width; small enough to cache.
    static let bucketCount = 800

    enum Failure: Error { case noAudioTrack, unreadable }

    static func peaks(for url: URL, buckets: Int = bucketCount) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8000,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.unreadable }

        let totalSamples = max(1, Int(duration * 8000))
        let samplesPerBucket = max(1, totalSamples / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var consumed = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let count = length / 2
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                for i in 0..<count {
                    let bucket = min(buckets - 1, (consumed + i) / samplesPerBucket)
                    let v = abs(Float(samples[i])) / 32768
                    if v > peaks[bucket] { peaks[bucket] = v }
                }
            }
            consumed += count
        }
        if reader.status == .failed { throw reader.error ?? Failure.unreadable }
        return normalized(peaks)
    }

    /// Scale so the loudest moment hits the top; a quiet recording still
    /// shows a shape. Soft-knee so a single clap doesn't flatten speech.
    static func normalized(_ peaks: [Float]) -> [Float] {
        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { sqrt(min(1, $0 / loudest)) }
    }

    /// The slice of a source's peaks that a clip actually shows, resampled
    /// to `count` bars so it fills whatever width the timeline gives it.
    static func bars(from peaks: [Float], sourceDuration: Double, inPoint: Double, outPoint: Double, count: Int) -> [Float] {
        guard !peaks.isEmpty, sourceDuration > 0, count > 0, outPoint > inPoint else { return [] }
        let lo = Double(peaks.count) * inPoint / sourceDuration
        let hi = Double(peaks.count) * outPoint / sourceDuration
        let span = hi - lo
        return (0..<count).map { i in
            let a = Int(lo + span * Double(i) / Double(count))
            let b = max(a + 1, Int(lo + span * Double(i + 1) / Double(count)))
            let range = max(0, min(a, peaks.count - 1))...max(0, min(b - 1, peaks.count - 1))
            return peaks[range].max() ?? 0
        }
    }
}
