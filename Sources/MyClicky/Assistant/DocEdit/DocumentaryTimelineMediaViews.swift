import SwiftUI
import CoreGraphics

struct DocumentaryWaveformView: View {
    let peaks: [Float]      // each 0...1, already normalised
    let color: Color
    var progress: Double = 1
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            
            var playedPath = Path()
            var unplayedPath = Path()
            let centerY = size.height / 2
            let barWidth = max(1, size.width / CGFloat(peaks.count) * 0.7)
            let playedCount = Int((min(max(progress, 0), 1) * Double(peaks.count)).rounded())
            
            for (i, peak) in peaks.enumerated() {
                let x = size.width * (CGFloat(i) + 0.5) / CGFloat(peaks.count)
                let halfHeight = max(1, CGFloat(peak) * size.height / 2)
                if i < playedCount {
                    playedPath.move(to: CGPoint(x: x, y: centerY - halfHeight))
                    playedPath.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
                } else {
                    unplayedPath.move(to: CGPoint(x: x, y: centerY - halfHeight))
                    unplayedPath.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
                }
            }
            
            context.stroke(playedPath, with: .color(color), lineWidth: barWidth)
            context.stroke(unplayedPath, with: .color(color.opacity(0.4)), lineWidth: barWidth)
            
            let centerLineRect = CGRect(x: 0, y: centerY - 0.5, width: size.width, height: 1)
            context.fill(Path(centerLineRect), with: .color(color.opacity(0.35)))
        }
    }
}

struct DocumentaryFilmstripView: View {
    let images: [CGImage]
    let tileWidth: CGFloat      // width of each tile in points, already computed by the caller
    let tileCount: Int          // number of tiles to draw
    var body: some View {
        if images.isEmpty || tileCount <= 0 {
            Color.clear
        } else {
            HStack(spacing: 0) {
                ForEach(0..<tileCount, id: \.self) { i in
                    Image(decorative: images[min(images.count - 1, i * images.count / tileCount)], scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: tileWidth)
                        .clipped()
                }
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
            .clipped()
        }
    }
}
