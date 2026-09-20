import AppKit
import SwiftUI

/// Shows one subtitle exactly as it will be burned in — the export's own
/// layer, scaled to fit. On the preview it sits where it will on the video;
/// on a style tile it's centred and shrunk to fit the tile.
struct CaptionLayerView: NSViewRepresentable {
    enum Placement: Equatable {
        /// Where it lands on a video of `render` shape filling the view.
        case onVideo
        /// Centred, shrunk so the whole caption fits the view.
        case fitted
    }

    var text: String
    var highlight: Int?
    var style: CaptionStyle
    /// Where the user dragged the subtitles to; nil is the style's spot.
    var anchor: CaptionAnchor? = nil
    var placement: Placement
    /// The frame the caption is laid out for.
    var render: CGSize = VideoExporter.renderSize

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.wantsLayer = true
        host.layer = CALayer()
        host.layer?.masksToBounds = false
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.draw(text: text, highlight: highlight, style: style, anchor: anchor, placement: placement, render: render)
    }

    final class Host: NSView {
        private var key: String?
        private var caption: CALayer?
        private var render = VideoExporter.renderSize

        override var isFlipped: Bool { false }

        override func layout() {
            super.layout()
            position()
        }

        @MainActor
        func draw(text: String, highlight: Int?, style: CaptionStyle, anchor: CaptionAnchor?, placement: Placement, render: CGSize) {
            let spot = anchor.map { "\($0.x),\($0.y)" } ?? "-"
            let next = "\(text)|\(highlight.map(String.init) ?? "-")|\(placement)|\(spot)|\(render)|\(style.hashKey)"
            guard next != key else { return }
            key = next
            caption?.removeFromSuperlayer()
            let layer = VideoExporter.captionLayer(text: text, highlight: highlight, style: style, anchor: anchor, render: render)
            caption = layer
            self.layer?.addSublayer(layer)
            self.placement = placement
            self.render = render
            position()
        }

        private var placement: Placement = .onVideo

        private func position() {
            guard let caption, bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch placement {
            case .onVideo:
                let scale = bounds.width / render.width
                caption.setAffineTransform(.identity)
                caption.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                // Frame is in render space; scale it into the view.
                let frame = caption.frame
                caption.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                caption.position = CGPoint(x: frame.midX * scale, y: frame.midY * scale)
            case .fitted:
                caption.setAffineTransform(.identity)
                let frame = caption.frame
                let scale = min(bounds.width * 0.86 / max(frame.width, 1),
                                bounds.height * 0.72 / max(frame.height, 1))
                caption.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                caption.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                caption.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            CATransaction.commit()
        }
    }
}

extension CaptionStyle {
    /// Cheap change detection for the host view.
    var hashKey: String {
        "\(face)\(fontSize)\(italic)\(uppercase)\(textColor)\(String(describing: accentColor))\(String(describing: pillColor))" +
        "\(cornerRadius)\(String(describing: strokeColor))\(strokeWidth)\(String(describing: shadowColor))\(shadowRadius)\(shadowOffset)"
    }
}
