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
}
