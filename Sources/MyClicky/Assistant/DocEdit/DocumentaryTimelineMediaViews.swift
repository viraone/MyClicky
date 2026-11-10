import SwiftUI
import CoreGraphics

struct DocumentaryWaveformView: View {
    let peaks: [Float]      // each 0...1, already normalised
    let color: Color
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            
            var path = Path()
            let centerY = size.height / 2
            let barWidth = max(1, size.width / CGFloat(peaks.count) * 0.7)
            
            for (i, peak) in peaks.enumerated() {
                let x = size.width * (CGFloat(i) + 0.5) / CGFloat(peaks.count)
                let halfHeight = max(1, CGFloat(peak) * size.height / 2)
                path.move(to: CGPoint(x: x, y: centerY - halfHeight))
                path.addLine(to: CGPoint(x: x, y: centerY + halfHeight))
            }
            
            context.stroke(path, with: .color(color), lineWidth: barWidth)
            
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
