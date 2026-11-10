import SwiftUI

struct DocumentaryTimelineView: View {
    let chapters: [CodeDocumentaryModel.Chapter]
    let duration: Double
    let playhead: Double
    let isPlaying: Bool
    let accent: Color
    var film: URL? = nil
    let onSeek: (Double) -> Void
    @State private var zoom: Double? = nil      // nil = fit
    @State private var lastViewW: CGFloat = 600
    @State private var peaks: [Float] = []
    @State private var images: [CGImage] = []

    private let rulerH: CGFloat = 24
    private let sceneH: CGFloat = 38
    private let videoH: CGFloat = 56
    private let narrationH: CGFloat = 56
    private var lanesH: CGFloat { rulerH + sceneH + videoH + narrationH }
    private let labelW: CGFloat = 96
    private let headerH: CGFloat = 28

    var body: some View {
        if duration <= 0 || chapters.isEmpty {
            Color.clear.frame(height: 0)
        } else {
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    labelColumn
                    GeometryReader { geo in
                        lanes(viewW: geo.size.width)
                            .onAppear { lastViewW = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in
                                lastViewW = newWidth
                            }
                    }
                    .frame(height: lanesH)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10)))
            .accessibilityIdentifier("documentaryTimeline")
            .task(id: film) {
                guard let film else { peaks = []; images = []; return }
                peaks = await DocumentaryTimelineMedia.waveformPeaks(url: film, buckets: 600)
                images = await DocumentaryTimelineMedia.thumbnails(url: film, count: 60, maxHeight: 112)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("TIMELINE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                zoom = DocumentaryTimelineMath.clampZoom(pxPerSec(viewW: lastViewW) / 1.4)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Button {
                zoom = DocumentaryTimelineMath.clampZoom(pxPerSec(viewW: lastViewW) * 1.4)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Button {
                zoom = nil
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .frame(height: headerH)
    }

    private var labelColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerH)
            labelRow("captions.bubble", "SCENES", sceneH)
            labelRow("film", "VIDEO", videoH)
            labelRow("waveform", "AUDIO", narrationH)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
        }
    }

    private func labelRow(_ icon: String, _ label: String, _ h: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: labelW, height: h, alignment: .leading)
        .padding(.leading, 8)
    }

    private func pxPerSec(viewW: CGFloat) -> Double {
        zoom ?? DocumentaryTimelineMath.fitZoom(viewWidth: Double(viewW), duration: duration)
    }

    private func lanes(viewW: CGFloat) -> some View {
        let px = pxPerSec(viewW: viewW)
        let contentW = CGFloat(DocumentaryTimelineMath.contentWidth(viewWidth: Double(viewW), duration: duration, pxPerSec: px))
        let active = DocumentaryTimelineMath.activeIndex(ranges: chapters.map { (start: $0.start, end: $0.end) }, at: playhead)
        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ruler(px)
                sceneLane(px, active)
                videoLane(px)
                audioLane(px)
                narrationLane(px, active)
                playheadView(px)
                scrubSurface(px)
            }
            .frame(width: contentW, height: lanesH, alignment: .topLeading)
        }
    }

    private func ruler(_ px: Double) -> some View {
        let major = DocumentaryTimelineMath.majorStep(pxPerSec: px)
        let minor = DocumentaryTimelineMath.minorStep(major: major)
        return ZStack(alignment: .topLeading) {
            ForEach(0...min(Int(duration / minor), 2000), id: \.self) { i in
                let t = Double(i) * minor
                let isMajor = abs(t / major - (t / major).rounded()) < 1e-6
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: isMajor ? 12 : 6)
                    .offset(x: CGFloat(t * px), y: 0)
                if isMajor {
                    Text(DocumentaryTimelineMath.rulerLabel(t, major: major))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .offset(x: CGFloat(t * px) + 4, y: 6)
                        .fixedSize()
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .offset(y: rulerH - 1)
        }
    }

    private func sceneLane(_ px: Double, _ active: Int?) -> some View {
        ForEach(Array(chapters.enumerated()), id: \.element.id) { i, c in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(i == active ? accent.opacity(0.25) : Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(i == active ? accent : Color.white.opacity(0.18), lineWidth: i == active ? 2 : 1.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(i + 1) · \(c.heading)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(4)
            }
            .frame(width: CGFloat(DocumentaryTimelineMath.clipWidth(start: c.start, end: c.end, pxPerSec: px)), height: sceneH - 8, alignment: .topLeading)
            .clipped()
            .offset(x: CGFloat(c.start * px), y: rulerH + 4)
            .allowsHitTesting(false)
        }
    }

    private func narrationLane(_ px: Double, _ active: Int?) -> some View {
        ForEach(Array(chapters.enumerated()), id: \.element.id) { i, c in
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(i == active ? accent : Color.yellow.opacity(0.30), lineWidth: i == active ? 2 : 1)
                )
                .frame(width: CGFloat(DocumentaryTimelineMath.clipWidth(start: c.start, end: c.end, pxPerSec: px)), height: narrationH - 8, alignment: .leading)
                .clipped()
                .offset(x: CGFloat(c.start * px), y: rulerH + sceneH + videoH + 4)
                .allowsHitTesting(false)
        }
    }

    private func videoLane(_ px: Double) -> some View {
        let laneW = CGFloat(duration * px)
        let aspect = images.first.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.5625
        let tileW = max(8, (videoH - 8) * aspect)
        let tileCount = max(1, Int((laneW / tileW).rounded(.up)))
        return DocumentaryFilmstripView(images: images, tileWidth: tileW, tileCount: tileCount)
            .frame(width: laneW, height: videoH - 8, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .offset(x: 0, y: rulerH + sceneH + 4)
            .allowsHitTesting(false)
    }

    private func audioLane(_ px: Double) -> some View {
        DocumentaryWaveformView(peaks: peaks, color: Color.yellow.opacity(0.9))
            .frame(width: CGFloat(duration * px), height: narrationH - 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08)))
            .offset(x: 0, y: rulerH + sceneH + videoH + 4)
            .allowsHitTesting(false)
    }

    private func playheadView(_ px: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(accent).frame(width: 1, height: lanesH)
            RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 16, height: 12)
        }
        .frame(width: 16, height: lanesH, alignment: .top)
        .offset(x: CGFloat(playhead * px) - 8, y: 0)
        .allowsHitTesting(false)
    }

    private func scrubSurface(_ px: Double) -> some View {
        Color.clear
            .frame(height: lanesH)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        onSeek(DocumentaryTimelineMath.time(atX: Double(v.location.x), pxPerSec: px, duration: duration))
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

