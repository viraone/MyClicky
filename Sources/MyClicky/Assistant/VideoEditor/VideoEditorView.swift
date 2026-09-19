import AVKit
import SwiftUI

/// The Peeky Video tab, built for someone who has never edited video.
/// A four-step tracker across the top says where you are and what to do
/// next; every control is a labelled button; the preview is big.
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let accent: Color
    @State private var newProjectName = ""

    var body: some View {
        Group {
            if model.hasProject { editor } else { start }
        }
        .font(.system(size: 13, design: .monospaced))
        // The panel can be squeezed very short; whatever doesn't fit must
        // stay inside this tab rather than draw over the header above.
        .clipped()
    }

    // MARK: - Start screen

    private var start: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(accent)
                    Text("Peeky Video")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Turn your takes into a subtitled 9:16 video for Reels, TikTok and your portfolio.")
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                // The one big thing to do.
                Button { model.chooseClips() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 30, weight: .regular))
                        Text("Import your video clips")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                        Text("Click to choose files — or drop them anywhere on this tab")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: 520)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                            .foregroundStyle(accent.opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 520)

                HStack(spacing: 8) {
                    TextField("Or name a project first…", text: $newProjectName)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        .onSubmit(createProject)
                    pillButton("Create", icon: "plus", action: createProject)
                        .opacity(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
                .frame(maxWidth: 520)

                if !model.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("RECENT PROJECTS")
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(model.recentProjects, id: \.self) { folder in
                                    Button { model.open(folder: folder) } label: {
                                        HStack {
                                            Image(systemName: "folder.fill").foregroundStyle(accent.opacity(0.8))
                                            Text(folder.lastPathComponent)
                                            Spacer()
                                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .frame(maxWidth: 520)
                }

                if case .failed(let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 520)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.newProject(named: name)
        newProjectName = ""
    }

    // MARK: - Editor

    private var editor: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                // The header and the "what to do next" line stay put, so
                // the guidance is always in view however far you scroll.
                header
                coachLine
                // Scrolls when the panel is shorter than the editor; at full
                // height it's a no-op and everything is where it always was.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        // The video sits on top, centred, like a phone held up,
                        // and takes the lion's share of the height the way an
                        // editor's canvas does; everything else is underneath.
                        preview(height: max(220, min(geo.size.height * 0.56, 820)))
                            .frame(maxWidth: .infinity)
                        timelineCard
                        controlsCard
                        captionsCard
                    }
                    .frame(width: geo.size.width, alignment: .top)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    // MARK: Header

    /// One slim row: project on the left, the four steps in the middle,
    /// Import / Export on the right.
    private var header: some View {
        HStack(spacing: 10) {
            Button { model.closeProject() } label: {
                Label("Projects", systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .help("Back to the project list")

            Text(model.project?.name ?? "")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            Button { model.revealProject() } label: { Image(systemName: "folder") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("Show this project's folder in Finder")
            Spacer(minLength: 8)
            stepTracker
            Spacer(minLength: 8)
            pillButton("Import clips", icon: "square.and.arrow.down") { model.chooseClips() }
                .help("Add more takes or screen recordings")
            pillButton("Export video", icon: "square.and.arrow.up", prominent: true) { model.export() }
                .disabled(!hasClips)
                .opacity(hasClips ? 1 : 0.45)
                .help("Save the finished MP4 at 1080 × 1920 with subtitles burned in")
        }
        .disabled(model.phase.isBusy)
    }

    // MARK: Steps

    private enum Step: Int, CaseIterable {
        case importClips, trim, captions, export

        var title: String {
            switch self {
            case .importClips: "Import"
            case .trim: "Trim"
            case .captions: "Subtitles"
            case .export: "Export"
            }
        }

        var icon: String {
            switch self {
            case .importClips: "square.and.arrow.down"
            case .trim: "scissors"
            case .captions: "captions.bubble"
            case .export: "square.and.arrow.up"
            }
        }
    }

    private var hasClips: Bool { !(model.project?.clips.isEmpty ?? true) }
    private var hasCaptions: Bool { !(model.project?.timelineCues.isEmpty ?? true) }
    private var hasExport: Bool { model.lastExport != nil }

    private var currentStep: Step {
        if !hasClips { return .importClips }
        if !hasCaptions { return .trim }
        if !hasExport { return .export }
        return .export
    }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .importClips: hasClips
        case .trim: hasCaptions     // Trimming is optional; captions mean you moved on.
        case .captions: hasCaptions
        case .export: hasExport
        }
    }

    private func perform(_ step: Step) {
        switch step {
        case .importClips: model.chooseClips()
        case .trim: model.seek(to: model.currentTime)
        case .captions: model.generateCaptions()
        case .export: model.export()
        }
    }

    private var stepTracker: some View {
        HStack(spacing: 4) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                stepChip(step)
                if step != .export {
                    Rectangle()
                        .fill(isDone(step) ? accent.opacity(0.6) : Color.white.opacity(0.12))
                        .frame(width: 10, height: 1.5)
                }
            }
        }
        .fixedSize()
    }

    private func stepChip(_ step: Step) -> some View {
        let done = isDone(step)
        let current = step == currentStep && !done
        let available = step == .importClips || hasClips
        return Button { perform(step) } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(done ? accent : (current ? accent.opacity(0.22) : Color.white.opacity(0.08)))
                        .frame(width: 18, height: 18)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    } else {
                        Text("\(step.rawValue + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(current ? accent : .white.opacity(0.6))
                    }
                }
                Text(step.title)
                    .font(.system(size: 11, weight: current ? .bold : .semibold, design: .monospaced))
                    .foregroundStyle(current ? .white : .white.opacity(done ? 0.85 : 0.5))
            }
            .padding(.leading, 5).padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(current ? accent.opacity(0.15) : Color.white.opacity(0.04))
            )
            .overlay(
                Capsule().strokeBorder(current ? accent.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!available || model.phase.isBusy)
        .opacity(available ? 1 : 0.5)
        .help(stepHelp(step))
    }

    private func stepHelp(_ step: Step) -> String {
        switch step {
        case .importClips: "Choose the takes and screen recordings for this video"
        case .trim: "Watch it back and cut out the bits you don't want"
        case .captions: "Listen to every take and lay word-timed subtitles on the video"
        case .export: "Save the finished MP4 (1080 × 1920) with its .srt and transcript"
        }
    }

    // MARK: Coach line

    /// One sentence about what's happening or what to do next.
    private var coachLine: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .importing(let i, let n):
                ProgressView().controlSize(.small).tint(accent)
                coachText("Reading clip \(i) of \(n)…")
            case .transcribing(let l):
                ProgressView(value: l.fraction).frame(width: 160).tint(accent)
                coachText(l.count > 1
                          ? "Listening to take \(l.index) of \(l.count) — \(VideoEditorModel.clock(l.secondsHeard)) of \(VideoEditorModel.clock(l.duration)) heard. Words appear below as it goes."
                          : "Listening — \(VideoEditorModel.clock(l.secondsHeard)) of \(VideoEditorModel.clock(l.duration)) heard. Words appear below as it goes.")
            case .translating(let n):
                ProgressView().controlSize(.small).tint(accent)
                coachText("Translating \(n) subtitle\(n == 1 ? "" : "s") into \(SubtitleLanguages.name(ofLanguage: model.translationLanguage ?? ""))…")
            case .exporting(let p):
                ProgressView(value: p).frame(width: 160).tint(accent)
                coachText("Exporting your video… \(Int(p * 100))%")
            case .exported(let url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                coachText("Done! Saved \(url.lastPathComponent) with its subtitles (.srt) and transcript (.txt).")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).foregroundStyle(accent).fontWeight(.semibold)
                Spacer()
                dismissButton
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                dismissButton
            case .idle:
                Image(systemName: "lightbulb.fill").foregroundStyle(accent.opacity(0.9))
                coachText(model.note ?? nextHint)
            }
            if !isTerminal(model.phase) { Spacer() }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func isTerminal(_ phase: VideoEditorModel.Phase) -> Bool {
        switch phase {
        case .exported, .failed: true
        default: false
        }
    }

    private func coachText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var dismissButton: some View {
        Button { model.dismissPhase() } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.4))
            .help("Dismiss")
    }

    private var nextHint: String {
        switch currentStep {
        case .importClips:
            "Step 1 — Press Import clips (top right) or drop your video files here."
        case .trim:
            "Step 2 — Press Play to watch. Stop where you want to cut, then use Split, Cut before or Cut after. When it looks right, press Auto-subtitle."
        case .captions:
            "Step 3 — Press Auto-subtitle to transcribe your takes."
        case .export:
            hasExport
                ? "All done. Import more clips or re-export any time."
                : "Step 4 — Read the subtitles below and fix any words. Then press Export video."
        }
    }

    // MARK: Preview

    private func preview(height: CGFloat) -> some View {
        let width = height * 9 / 16
        return ZStack {
            VideoEditorSurface(player: model.player)
            if !hasClips {
                VStack(spacing: 10) {
                    Image(systemName: "iphone").font(.system(size: 36, weight: .thin))
                    Text("Your video shows here").font(.system(size: 12, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.35))
            } else if !model.isPlaying {
                // A big, obvious play button while paused.
                Button { model.togglePlay() } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if let cue = model.currentCue {
                VStack {
                    Spacer()
                    Text(cue.displayText)
                        .font(.system(size: max(11, height * 0.028), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.65)))
                        .padding(.horizontal, width * 0.08)
                    // Same spot as the burned-in caption: its centre 30% up.
                    Spacer().frame(height: height * model.style.centreFromBottom - 14)
                }
            }
            if hasClips {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Spacer()
                        if let zoom = model.selectedClip?.zoom, zoom > 1.01 {
                            badge(String(format: "%.1f×", zoom), tint: accent)
                        }
                        badge("9:16", tint: .white.opacity(0.5))
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: width, height: height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .onTapGesture { if hasClips { model.togglePlay() } }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    guard hasClips, let base = pinchBaseZoom ?? model.selectedClip?.zoom else { return }
                    if pinchBaseZoom == nil { pinchBaseZoom = base }
                    model.setZoom(base * value)
                }
                .onEnded { _ in pinchBaseZoom = nil }
        )
    }

    @State private var pinchBaseZoom: Double?

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: Timeline

    private var timelineCard: some View {
        card(title: "TIMELINE", trailing: hasClips ? "\(model.project?.clips.count ?? 0) clip\(model.project?.clips.count == 1 ? "" : "s") · \(VideoEditorModel.clock(model.duration))" : nil) {
            VStack(alignment: .leading, spacing: 8) {
                if hasClips {
                    timelineStrip
                    HStack(spacing: 6) {
                        Text(VideoEditorModel.clock(model.currentTime))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                        Text("/ \(VideoEditorModel.clock(model.duration))")
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if let clip = model.selectedClip {
                            Label("\(clip.name)  \(VideoEditorModel.clock(clip.inPoint))–\(VideoEditorModel.clock(clip.outPoint))", systemImage: "film")
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    Text(scrubbing
                         ? "Let go to stop at \(VideoEditorModel.clock(model.currentTime))."
                         : "Click anywhere on the timeline to jump there, or drag to scrub. The bars are the sound: tall where you're talking, flat in the gaps — cut in a gap.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                } else {
                    emptyRow(icon: "square.and.arrow.down", text: "Your clips will line up here in the order they'll play.")
                }
            }
        }
    }

    private var timelineStrip: some View {
        GeometryReader { geo in
            let total = max(model.duration, 0.001)
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    if let project = model.project {
                        ForEach(project.clips) { clip in
                            clipBlock(clip, width: max(6, geo.size.width * clip.duration / total - 3))
                        }
                    }
                }
                // Playhead
                let x = geo.size.width * min(model.currentTime / total, 1)
                VStack(spacing: 0) {
                    Triangle()
                        .fill(accent)
                        .frame(width: 10, height: 6)
                    Rectangle()
                        .fill(accent)
                        .frame(width: 2)
                }
                .frame(height: 68)
                .offset(x: x - 5)
                .shadow(color: accent.opacity(0.7), radius: 3)
                .allowsHitTesting(false)

                // Seams that can be healed: a faint stitch mark always, and
                // a Rejoin pill when the mouse rests near one.
                if let project = model.project {
                    ForEach(healableSeams(in: project), id: \.self) { index in
                        let seamX = geo.size.width * project.clipStarts[index + 1] / total
                        let near = hoverX.map { abs($0 - seamX) < 16 } ?? false
                        if near {
                            rejoinPill(index: index)
                                .position(x: seamX, y: 34)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        } else {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                                .position(x: seamX, y: 34)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: 68)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop(); hoverX = nil }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoverX == nil)
            // One gesture covers both a click (jump there) and a drag (scrub).
            // The clip under the new time becomes the selected clip.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = true
                        model.seek(to: total * min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { value in
                        scrubbing = false
                        model.seek(to: total * min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
        }
        .frame(height: 68)
    }

    @State private var scrubbing = false
    /// Where the mouse is over the timeline strip, for the Rejoin pill.
    @State private var hoverX: CGFloat?

    /// Indices i where clip i and clip i+1 are the same footage back to back.
    private func healableSeams(in project: VideoProject) -> [Int] {
        project.clips.indices.dropLast().filter { project.canRejoin(after: $0) }
    }

    /// Straddles a healed-able seam: one click glues the two halves back.
    private func rejoinPill(index: Int) -> some View {
        Button { model.rejoin(after: index) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .black))
                Text("Rejoin").font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(accent))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("These two pieces are the same footage back to back — click to make them one clip again")
    }

    private func clipBlock(_ clip: EditClip, width: CGFloat) -> some View {
        let selected = clip.id == model.selectedClipID
        return ZStack(alignment: .topLeading) {
                waveform(for: clip, width: width)
                HStack(spacing: 5) {
                    Text(clip.name)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text(VideoEditorModel.clock(clip.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    if !clip.cues.isEmpty {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 9))
                            .foregroundStyle(accent.opacity(0.9))
                    }
                    if clip.zoom > 1.01 {
                        Text(String(format: "%.1f×", clip.zoom))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(5)
                .frame(maxWidth: width, alignment: .leading)
            }
            .frame(width: width, height: 68, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent.opacity(0.32) : Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent : Color.white.opacity(0.14), lineWidth: selected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white.opacity(0.9))
            .help("\(clip.source.path)\nClick anywhere on the timeline to jump there; drag to scrub.")
    }

    /// The sound inside the clip as a soft mirrored shape: tall where
    /// someone's talking, thin in the gaps. What's already played is tinted
    /// so the playhead has a trail.
    @ViewBuilder
    private func waveform(for clip: EditClip, width: CGFloat) -> some View {
        let step: CGFloat = 3
        let count = max(2, Int(width / step))
        if let raw = model.waveformBars(for: clip, count: count) {
            let bars = smoothed(raw)
            let played = playedFraction(of: clip)
            Canvas { context, size in
                let mid = size.height / 2
                let amp = (size.height - 14) / 2
                var shape = Path()
                shape.move(to: CGPoint(x: 0, y: mid))
                for (i, level) in bars.enumerated() {
                    shape.addLine(to: CGPoint(x: CGFloat(i) * step, y: mid - max(1, CGFloat(level) * amp)))
                }
                shape.addLine(to: CGPoint(x: CGFloat(bars.count - 1) * step, y: mid))
                for (i, level) in bars.enumerated().reversed() {
                    shape.addLine(to: CGPoint(x: CGFloat(i) * step, y: mid + max(1, CGFloat(level) * amp)))
                }
                shape.closeSubpath()

                let quiet = Gradient(colors: [.white.opacity(0.42), .white.opacity(0.16), .white.opacity(0.42)])
                let loud = Gradient(colors: [accent.opacity(0.95), accent.opacity(0.55), accent.opacity(0.95)])
                let top = CGPoint(x: 0, y: 0), bottom = CGPoint(x: 0, y: size.height)
                context.fill(shape, with: .linearGradient(quiet, startPoint: top, endPoint: bottom))
                if played > 0 {
                    var trail = context
                    trail.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * played, height: size.height)))
                    trail.fill(shape, with: .linearGradient(loud, startPoint: top, endPoint: bottom))
                }
                // A hairline through the middle so silence still reads as a track.
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid))
                line.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            .frame(width: width, height: 68)
            .allowsHitTesting(false)
        } else if model.waveforms[clip.source.path] == nil {
            HStack {
                Spacer()
                ProgressView().controlSize(.mini).opacity(0.5)
                Spacer()
            }
            .frame(width: width, height: 68)
        }
    }

    /// Three-tap average so the shape rolls instead of spiking.
    private func smoothed(_ bars: [Float]) -> [Float] {
        guard bars.count > 2 else { return bars }
        return bars.indices.map { i in
            let a = bars[max(0, i - 1)], b = bars[i], c = bars[min(bars.count - 1, i + 1)]
            return (a + 2 * b + c) / 4
        }
    }

    /// How much of this clip is behind the playhead, 0…1.
    private func playedFraction(of clip: EditClip) -> CGFloat {
        guard let start = model.project?.start(of: clip.id), clip.duration > 0 else { return 0 }
        return CGFloat(min(max((model.currentTime - start) / clip.duration, 0), 1))
    }

    // MARK: Controls

    private var controlsCard: some View {
        // No header row: the CONTROLS label rides in the spare space at the
        // trailing end of the groups instead, so the card is one row tall.
        card(title: nil, trailing: nil) {
            // Four groups side by side when there's room; otherwise the
            // groups wrap onto two rows rather than pushing the panel wider.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    watchGroup
                    groupDivider
                    cutGroup
                    groupDivider
                    zoomGroup
                    groupDivider
                    clipGroup
                    Spacer(minLength: 12)
                    sectionLabel("CONTROLS")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 18) {
                        watchGroup
                        groupDivider
                        cutGroup
                        Spacer(minLength: 12)
                        sectionLabel("CONTROLS")
                    }
                    HStack(alignment: .top, spacing: 18) {
                        zoomGroup
                        groupDivider
                        clipGroup
                        Spacer(minLength: 0)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("CONTROLS")
                    watchGroup
                    cutGroup
                    zoomGroup
                    clipGroup
                }
            }
            .disabled(!hasClips || model.phase.isBusy)
            .opacity(hasClips ? 1 : 0.4)
        }
    }

    private var watchGroup: some View {
        controlGroup("WATCH") {
            tile(model.isPlaying ? "pause.fill" : "play.fill", model.isPlaying ? "Pause" : "Play",
                 help: "Play or pause") { model.togglePlay() }
            tile("backward.end.fill", "Start", help: "Jump to the beginning") { model.seek(to: 0) }
            tile("gobackward.5", "−5 s", help: "Go back five seconds") { model.seek(to: model.currentTime - 5) }
            tile("goforward.5", "+5 s", help: "Go forward five seconds") { model.seek(to: model.currentTime + 5) }
        }
    }

    private var cutGroup: some View {
        controlGroup("CUT AT THE PLAYHEAD") {
            tile("scissors", "Split", help: "Cut the clip into two at the playhead — then remove the half you don't want") { model.splitAtPlayhead() }
            tile("arrow.right.to.line", "Cut before", help: "Throw away everything in this clip before the playhead") { model.trimStartToPlayhead() }
            tile("arrow.left.to.line", "Cut after", help: "Throw away everything in this clip after the playhead") { model.trimEndToPlayhead() }
        }
    }

    private var zoomGroup: some View {
        let zoom = model.selectedClip?.zoom ?? 1
        return controlGroup("ZOOM  \(String(format: "%.1f×", zoom))") {
            tile("minus.magnifyingglass", "Out", help: "Zoom out (or pinch on the video)") { model.zoom(by: 1 / 1.15) }
            tile("plus.magnifyingglass", "In", help: "Zoom in — crops from the centre (or pinch on the video)") { model.zoom(by: 1.15) }
            tile("rectangle.arrowtriangle.2.inward", "Fill", help: "Zoom just enough that the picture fills the whole 9:16 frame with no black bars") { model.zoomToFill() }
            tile("rectangle.arrowtriangle.2.outward", "Fit", help: "Show the whole picture (black bars if it's landscape)") { model.setZoom(1) }
        }
    }

    private var clipGroup: some View {
        controlGroup("THIS CLIP") {
            tile("arrow.left", "Earlier", help: "Move the highlighted clip one place earlier") { model.moveSelectedClip(by: -1) }
            tile("arrow.right", "Later", help: "Move the highlighted clip one place later") { model.moveSelectedClip(by: 1) }
            tile("trash", "Remove", help: "Take the highlighted clip out of the video (the file stays on disk)", destructive: true) { model.removeSelectedClip() }
        }
    }

    private var groupDivider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 64)
    }

    private func controlGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) { content() }
        }
    }

    private func tile(_ symbol: String, _ title: String, help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : .white.opacity(0.9))
            .frame(width: 66, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Subtitles

    /// VEED's Subtitles panel, at home in Peeky: pick the spoken language,
    /// optionally a translation, press the big green button, then fix any
    /// words in the list below.
    private var captionsCard: some View {
        let count = model.project?.timelineCues.count ?? 0
        return card(title: "SUBTITLES", trailing: hasCaptions ? "\(count) line\(count == 1 ? "" : "s") · click a time to jump, click words to edit" : nil) {
            VStack(alignment: .leading, spacing: 12) {
                if hasClips {
                    subtitleSettings
                } else {
                    emptyRow(icon: "captions.bubble",
                             text: "Import clips first — then Peeky can transcribe them into subtitles.")
                }
                if let cues = model.project?.timelineCues, !cues.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(cues) { cue in cueRow(cue) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(translationRunner)
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What language is being spoken?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            spokenLanguagePicker

            HStack(spacing: 10) {
                Text("Add translation")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if model.translationEnabled {
                    translationLanguagePicker
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.translationEnabled },
                    set: { model.setTranslationEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
                .help("Put a second, translated line under every subtitle")
            }
            .frame(minHeight: 28)

            if case .transcribing(let listening) = model.phase {
                listeningPanel(listening)
            } else {
                autoSubtitleButton
            }
        }
    }

    /// What replaces the green button while Peeky listens: how far it is,
    /// the words as they arrive, and a way to stop.
    private func listeningPanel(_ l: VideoEditorModel.Listening) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(accent)
                Text(l.count > 1 ? "Listening to \(l.clipName) — take \(l.index) of \(l.count)" : "Listening to \(l.clipName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                Text("\(VideoEditorModel.clock(l.secondsHeard)) / \(VideoEditorModel.clock(l.duration))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                Text("\(Int(l.fraction * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, alignment: .trailing)
            }
            ProgressView(value: l.fraction)
                .tint(accent)
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
                Text(l.latestText.isEmpty ? "Warming up — the first words take a few seconds…" : "…\(l.latestText)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(l.latestText.isEmpty ? .white.opacity(0.45) : .white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: l.latestText)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            HStack(spacing: 10) {
                Text("Peeky is turning the speech into text on this Mac — nothing is uploaded. It runs about as fast as the clip plays; you can keep trimming meanwhile.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                pillButton("Stop", icon: "stop.fill") { model.stopSubtitling() }
                    .help("Stop listening. What's been heard so far is kept, so you can carry on later.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1))
    }

    private var spokenLanguagePicker: some View {
        let locale = model.spokenLocale
        return HStack(spacing: 10) {
            Text(SubtitleLanguages.regionChip(of: locale))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
            Text(SubtitleLanguages.name(of: locale))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text(SubtitleLanguages.fullName(of: locale))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
            Text("Change")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .overlay(invisibleMenu {
            ForEach(VideoTranscriber.supportedLocales, id: \.identifier) { option in
                Button {
                    model.setSpokenLanguage(option.identifier)
                } label: {
                    HStack {
                        Text("\(SubtitleLanguages.name(of: option)) — \(SubtitleLanguages.fullName(of: option))")
                        if option.identifier == locale.identifier { Image(systemName: "checkmark") }
                    }
                }
            }
        })
        .help("The language Peeky listens for when it transcribes — click to change")
    }

    private var translationLanguagePicker: some View {
        let current = model.translationLanguage ?? ""
        return HStack(spacing: 5) {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            Text(SubtitleLanguages.name(ofLanguage: current))
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(accent.opacity(0.14)))
        .overlay(invisibleMenu {
            ForEach(SubtitleLanguages.translationTargets, id: \.self) { code in
                Button {
                    model.setTranslationLanguage(code)
                } label: {
                    HStack {
                        Text(SubtitleLanguages.name(ofLanguage: code))
                        if code == current { Image(systemName: "checkmark") }
                    }
                }
            }
        })
        .help("The language to translate every subtitle into — click to change")
    }

    /// A menu that fills whatever it's laid over and draws nothing itself.
    /// macOS collapses a `Menu`'s custom label to its first piece of text,
    /// so the visible row is drawn separately and this catches the click.
    private func invisibleMenu<Items: View>(@ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) { Color.clear.contentShape(Rectangle()) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.phase.isBusy)
    }

    /// The one big button, VEED-green: "Auto-subtitle in English".
    private var autoSubtitleButton: some View {
        let lime = Color(red: 0.78, green: 0.95, blue: 0.40)
        let language = SubtitleLanguages.name(of: model.spokenLocale)
        let title = hasCaptions ? "Re-subtitle in \(language)" : "Auto-subtitle in \(language)"
        return Button { model.generateCaptions() } label: {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(lime))
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
        .opacity(model.phase.isBusy ? 0.5 : 1)
        .help(hasCaptions
              ? "Listen again to any take that hasn't been heard in \(language) and rewrite the subtitles"
              : "Listen to every take and write word-timed subtitles in \(language)")
    }

    /// Hosts Apple's on-device translator. It has to live in a view, so the
    /// model asks for a pass by bumping `translationJob` and this runs it.
    @ViewBuilder private var translationRunner: some View {
        if #available(macOS 15, *) {
            SubtitleTranslationRunner(model: model)
        }
    }

    private func cueRow(_ cue: TimelineCue) -> some View {
        let live = model.currentTime >= cue.start && model.currentTime < cue.end
        return HStack(alignment: .center, spacing: 10) {
            Button { model.seek(to: cue.start) } label: {
                Text(VideoEditorModel.clock(cue.start))
                    .font(.system(size: 11, weight: live ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(live ? accent : .white.opacity(0.5))
                    .frame(width: 58, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Jump to this moment")
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(
                    get: { cue.text },
                    set: { model.setCueText(cue.id, $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: live ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                if model.translationEnabled {
                    TextField(cue.translation == nil ? "translating…" : "", text: Binding(
                        get: { cue.translation ?? "" },
                        set: { model.setCueTranslation(cue.id, $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.85))
                    .disabled(cue.translation == nil)
                }
            }
            Button { model.removeCue(cue.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.35))
            .help("Remove this subtitle")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(live ? accent.opacity(0.18) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(live ? accent.opacity(0.6) : .clear, lineWidth: 1)
        )
    }

    // MARK: - Bits

    private func card<Content: View>(title: String?, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    sectionLabel(title)
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(.white.opacity(0.45))
    }

    private func emptyRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.35))
            Text(text)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pillButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? accent.opacity(0.28) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(prominent ? accent.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The preview player without AVKit's own controls; the transport is ours.
private struct VideoEditorSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
