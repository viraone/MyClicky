import Foundation

enum DocumentaryTimelineMath {
    static let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
    /// first step where step * pxPerSec >= 72, else the last step
    static func majorStep(pxPerSec: Double) -> Double {
        steps.first { $0 * pxPerSec >= 72 } ?? steps.last!
    }
    /// major / (major >= 1 ? 4 : 2)
    static func minorStep(major: Double) -> Double {
        major / (major >= 1 ? 4 : 2)
    }
    /// (viewWidth - 80) / max(duration, 0.01), never below 2
    static func fitZoom(viewWidth: Double, duration: Double) -> Double {
        max((viewWidth - 80) / max(duration, 0.01), 2)
    }
    /// max(viewWidth, duration * pxPerSec + 160)
    static func contentWidth(viewWidth: Double, duration: Double, pxPerSec: Double) -> Double {
        max(viewWidth, duration * pxPerSec + 160)
    }
    /// x / pxPerSec clamped to 0...duration
    static func time(atX x: Double, pxPerSec: Double, duration: Double) -> Double {
        min(max(x / pxPerSec, 0), duration)
    }
    /// max(6, (end - start) * pxPerSec)
    static func clipWidth(start: Double, end: Double, pxPerSec: Double) -> Double {
        max(6, (end - start) * pxPerSec)
    }
    /// major < 1: String(format: "%.1fs", t); else t < 60: "\(Int(t.rounded()))s"; else "m:ss" (minutes, then seconds zero-padded to 2 digits, seconds from Int(t.rounded()))
    static func rulerLabel(_ t: Double, major: Double) -> String {
        if major < 1 {
            return String(format: "%.1fs", t)
        } else if t < 60 {
            return "\(Int(t.rounded()))s"
        } else {
            let total = Int(t.rounded())
            return "\(total / 60):\(String(format: "%02d", total % 60))"
        }
    }
    /// first index with start <= t < end, else nil
    static func activeIndex(ranges: [(start: Double, end: Double)], at t: Double) -> Int? {
        ranges.firstIndex { $0.start <= t && t < $0.end }
    }
    /// clamp to 2...400
    static func clampZoom(_ z: Double) -> Double {
        min(max(z, 2), 400)
    }
    /// "m:ss.t" with tenths. total = Int((max(t, 0) * 10).rounded()); format String(format: "%d:%02d.%d", total / 600, (total / 10) % 60, total % 10)
    static func timecode(_ t: Double) -> String {
        let total = Int((max(t, 0) * 10).rounded())
        return String(format: "%d:%02d.%d", total / 600, (total / 10) % 60, total % 10)
    }
    /// The boundary nearest to t when abs(boundary - t) <= thresholdSeconds, else t unchanged. Empty boundaries -> t.
    static func snappedTime(_ t: Double, boundaries: [Double], thresholdSeconds: Double) -> Double {
        guard let nearest = boundaries.min(by: { abs($0 - t) < abs($1 - t) }) else { return t }
        return abs(nearest - t) <= thresholdSeconds ? nearest : t
    }
    /// let current = starts.last(where: { $0 <= t }); if let c = current, t - c > restartWindow { return c }; let before = starts.last(where: { $0 < (current ?? t) }); return before ?? 0
    static func previousSceneStart(starts: [Double], at t: Double, restartWindow: Double) -> Double {
        let current = starts.last(where: { $0 <= t })
        if let c = current, t - c > restartWindow { return c }
        let before = starts.last(where: { $0 < (current ?? t) })
        return before ?? 0
    }
    /// starts.first(where: { $0 > t + 0.001 })
    static func nextSceneStart(starts: [Double], at t: Double) -> Double? {
        starts.first(where: { $0 > t + 0.001 })
    }
    /// true when playheadX < scrollX + margin || playheadX > scrollX + viewW - margin
    static func needsFollow(playheadX: Double, scrollX: Double, viewW: Double, margin: Double) -> Bool {
        playheadX < scrollX + margin || playheadX > scrollX + viewW - margin
    }
}
