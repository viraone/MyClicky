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
    @State private var snapping = true
    @State private var peaks: [Float] = []
    @State private var images: [CGImage] = []
    @State private var hoverX: CGFloat? = nil
    @State private var scrollX: CGFloat = 0

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
        HStack(spacing: 10) {
            Text("TIMELINE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Text("\(chapters.count) scenes")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.leading, 8)
            Spacer()
            Text("\(DocumentaryTimelineMath.timecode(playhead)) / \(DocumentaryTimelineMath.timecode(duration))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button {
                onSeek(DocumentaryTimelineMath.previousSceneStart(starts: chapters.map(\.start), at: playhead, restartWindow: 1))
            } label: {
                Image(systemName: "arrow.left.to.line")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Previous scene")
            .accessibilityLabel("Previous scene")
            Button {
                if let t = DocumentaryTimelineMath.nextSceneStart(starts: chapters.map(\.start), at: playhead) {
                    onSeek(t)
                }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Next scene")
            .accessibilityLabel("Next scene")
            Button {
                snapping.toggle()
            } label: {
                Image(systemName: "magnet")
                    .font(.system(size: 13))
                    .foregroundStyle(snapping ? accent : .white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Snap to scene edges")
            .accessibilityLabel("Snap to scene edges")
            Button {
                zoom = DocumentaryTimelineMath.clampZoom(pxPerSec(viewW: lastViewW) / 1.4)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")
            .padding(.leading, 6)
            Button {
                zoom = DocumentaryTimelineMath.clampZoom(pxPerSec(viewW: lastViewW) * 1.4)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
            Button {
                zoom = nil
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Fit to window")
            .accessibilityLabel("Fit to window")
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
        .frame(width: labelW + 8)
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

    private struct DocumentaryTimelineScrollXKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private func hoverLine(_ px: Double, contentW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let hoverX {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: lanesH)
                    .offset(x: hoverX, y: 0)
                Text(DocumentaryTimelineMath.timecode(DocumentaryTimelineMath.time(atX: Double(hoverX), pxPerSec: px, duration: duration)))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: min(max(hoverX - 40, 0), contentW - 80), y: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func laneGuides(_ contentW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: rulerH)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: rulerH + sceneH)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: rulerH + sceneH + videoH)
        }
        .frame(width: contentW, height: lanesH)
        .allowsHitTesting(false)
    }

    private func lanes(viewW: CGFloat) -> some View {
        let px = pxPerSec(viewW: viewW)
        let contentW = CGFloat(DocumentaryTimelineMath.contentWidth(viewWidth: Double(viewW), duration: duration, pxPerSec: px))
        let active = DocumentaryTimelineMath.activeIndex(ranges: chapters.map { (start: $0.start, end: $0.end) }, at: playhead)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    scrubSurface(px)
                    laneGuides(contentW)
                    ruler(px)
                    sceneLane(px, active)
                    videoLane(px)
                    audioLane(px)
                    narrationLane(px, active)
                    playheadView(px)
                    hoverLine(px, contentW: contentW)
                    Color.clear.frame(width: 1, height: 1)
                        .offset(x: max(0, CGFloat(playhead * px) - 40))
                        .id("follow")
                }
                .frame(width: contentW, height: lanesH, alignment: .topLeading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: DocumentaryTimelineScrollXKey.self,
                                           value: -g.frame(in: .named("documentaryTimelineScroll")).minX)
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverX = p.x
                    case .ended: hoverX = nil
                    }
                }
            }
            .coordinateSpace(name: "documentaryTimelineScroll")
            .onPreferenceChange(DocumentaryTimelineScrollXKey.self) { scrollX = $0 }
            .onChange(of: playhead) { _, _ in
                if isPlaying, DocumentaryTimelineMath.needsFollow(playheadX: playhead * px, scrollX: Double(scrollX), viewW: Double(viewW), margin: 24) {
                    proxy.scrollTo("follow", anchor: .leading)
                }
            }
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
        .allowsHitTesting(false)
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
            .contentShape(Rectangle())
            .onTapGesture { onSeek(c.start) }
            .help(c.narration)
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
            .overlay {
                if images.isEmpty && film != nil {
                    Text("Loading frames...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .offset(x: 0, y: rulerH + sceneH + 4)
            .allowsHitTesting(false)
    }

    private func audioLane(_ px: Double) -> some View {
        DocumentaryWaveformView(peaks: peaks, color: Color.yellow.opacity(0.9), progress: duration > 0 ? playhead / duration : 0)
            .frame(width: CGFloat(duration * px), height: narrationH - 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08)))
            .offset(x: 0, y: rulerH + sceneH + videoH + 4)
            .allowsHitTesting(false)
    }

    private func playheadView(_ px: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(accent).frame(width: 1, height: lanesH)
            Text(DocumentaryTimelineMath.timecode(playhead))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(accent))
        }
        .frame(width: 56, height: lanesH, alignment: .top)
        .offset(x: CGFloat(playhead * px) - 28, y: 0)
        .allowsHitTesting(false)
    }

    private func scrubSurface(_ px: Double) -> some View {
        Color.clear
            .frame(height: lanesH)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let raw = DocumentaryTimelineMath.time(atX: Double(v.location.x), pxPerSec: px, duration: duration)
                        let edges = chapters.map(\.start) + (chapters.last.map { [$0.end] } ?? [])
                        onSeek(snapping ? DocumentaryTimelineMath.snappedTime(raw, boundaries: edges, thresholdSeconds: 6 / px) : raw)
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

