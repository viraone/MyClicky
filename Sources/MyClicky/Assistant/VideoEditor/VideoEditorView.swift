import AVKit
import SwiftUI

/// The Peeky Video tab, built for someone who has never edited video.
/// A four-step tracker across the top says where you are and what to do
/// next; every control is a labelled button; the preview is big. The
/// editor is laid out like VEED's: a rail of tools on the left, the open
/// tool's panel beside it, the video on a canvas, the timeline docked
/// along the bottom.
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let accent: Color
    @State private var newProjectName = ""
    /// Which tool panel sits open beside the rail. Nil until the user
    /// picks one, so the panel follows the current step at first.
    @State private var chosenTool: Tool?
    @State private var panelHidden = false

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

    /// VEED's editor shape: a rail of tools down the left, the open tool's
    /// panel beside it, the video on a canvas in the middle with a floating
    /// bar of quick actions under it, and the timeline docked along the
    /// bottom. Peeky's colours and coaching throughout.
    private var editor: some View {
        GeometryReader { geo in
            let showPanel = !panelHidden && geo.size.width >= 640
            let panelWidth = min(320, max(230, geo.size.width * 0.27))
            VStack(alignment: .leading, spacing: 10) {
                header
                coachLine
                HStack(alignment: .top, spacing: 10) {
                    rail
                    if showPanel {
                        toolPanel(activeTool)
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                timelineGrip(maxExtra: Self.maxTimelineExtra(for: geo.size.height))
                    .padding(.bottom, -6)
                timelineDock
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            // A timeline pulled tall on a big panel is reined in on a short one.
            .onChange(of: geo.size.height, initial: true) { _, height in
                let most = Double(Self.maxTimelineExtra(for: height))
                if timelineExtra > most { timelineExtra = most }
            }
        }
        // Hosts the on-device translator; it has to be somewhere that's
        // always on screen while a project is open.
        .background(translationRunner)
        .onChange(of: model.projectFolder) { _, _ in
            chosenTool = nil
            panelHidden = false
        }
    }

    // MARK: Tools

    /// The rail's entries: one panel per job, like VEED's left rail.
    private enum Tool: String, CaseIterable, Identifiable {
        case clips, trim, subtitles, style, export
        var id: String { rawValue }

        var title: String {
            switch self {
            case .clips: "Clips"
            case .trim: "Trim"
            case .subtitles: "Subtitles"
            case .style: "Style"
            case .export: "Export"
            }
        }

        var icon: String {
            switch self {
            case .clips: "film.stack"
            case .trim: "scissors"
            case .subtitles: "captions.bubble"
            case .style: "textformat"
            case .export: "square.and.arrow.up"
            }
        }

        var help: String {
            switch self {
            case .clips: "The takes in this video, in the order they play"
            case .trim: "Cut at the playhead and zoom the picture"
            case .subtitles: "Transcribe the takes and fix any words"
            case .style: "Pick the look of the subtitles"
            case .export: "Save the finished MP4"
            }
        }
    }

    /// Until the user picks a tool, the panel shows the step they're on.
    private var activeTool: Tool {
        if let chosenTool { return chosenTool }
        switch currentStep {
        case .importClips: return .clips
        case .trim: return .trim
        case .captions: return .subtitles
        case .export: return .export
        }
    }

    /// A rail click: open that tool, or fold the panel away if it's open.
    private func toggle(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if tool == activeTool && !panelHidden {
                panelHidden = true
            } else {
                chosenTool = tool
                panelHidden = false
            }
        }
    }

    private func open(_ tool: Tool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            chosenTool = tool
            panelHidden = false
        }
    }

    private var rail: some View {
        VStack(spacing: 4) {
            ForEach(Tool.allCases) { tool in railItem(tool) }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: 66)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func railItem(_ tool: Tool) -> some View {
        let open = tool == activeTool && !panelHidden
        let available = tool == .clips || hasClips
        let done: Bool = switch tool {
            case .clips: hasClips
            case .subtitles: hasCaptions
            case .export: hasExport
            case .trim, .style: false
        }
        return Button { toggle(tool) } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 26, height: 20)
                    .overlay(alignment: .topTrailing) {
                        if done {
                            Circle().fill(accent).frame(width: 6, height: 6).offset(x: 2, y: -2)
                        }
                    }
                Text(tool.title)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(open ? accent : Color.white.opacity(0.75))
            .frame(width: 54, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(open ? accent.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(open ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .help(tool.help)
    }

    @ViewBuilder private func toolPanel(_ tool: Tool) -> some View {
        switch tool {
        case .clips: clipsPanel
        case .trim: trimPanel
        case .subtitles: subtitlesPanel
        case .style: stylePanel
        case .export: exportPanel
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
        case .importClips: open(.clips); model.chooseClips()
        case .trim: open(.trim); model.seek(to: model.currentTime)
        case .captions: open(.subtitles); model.generateCaptions()
        case .export: open(.export); model.export()
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
            case .subtitled(let n):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                coachText("Done! \(n) subtitle\(n == 1 ? "" : "s") ready — they're on the video and in the Subtitles panel. Click a word there to fix it, then press Export video.")
                Spacer()
                dismissButton
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
        case .subtitled, .exported, .failed: true
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
            "Step 2 — Press Play to watch. Stop where you want to cut, then use Split, Cut before or Cut after. When it looks right, press Auto-subtitle under the video."
        case .captions:
            "Step 3 — Press Auto-subtitle under the video to transcribe your takes."
        case .export:
            hasExport
                ? "All done. Import more clips or re-export any time."
                : "Step 4 — Read the subtitles in the Subtitles panel and fix any words. Then press Export video."
        }
    }

    // MARK: Preview

    private func preview(height: CGFloat) -> some View {
        let width = height * 9 / 16
        return ZStack {
            VideoEditorSurface(player: model.player,
                               zoom: CGFloat(model.playheadClip?.zoom ?? 1),
                               pan: dragPan ?? model.playheadClip.map { CGSize(width: $0.panX, height: $0.panY) } ?? .zero,
                               clipID: model.playheadClip?.id)
            if hasClips { panHandle(width: width, height: height) }
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
                // The export's own caption layer, so the preview is exact.
                CaptionLayerView(text: cue.displayText,
                                 highlight: model.style.accentColor == nil ? nil : model.project?.wordIndex(in: cue, at: model.currentTime),
                                 style: model.style, anchor: dragAnchor ?? model.captionAnchor, placement: .onVideo)
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)
                captionHandle(for: cue, width: width, height: height)
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
    }

    /// The picture's spot while it's being dragged, and where the drag began.
    @State private var dragPan: CGSize?
    @State private var dragPanStart: CGSize?

    /// The whole picture is a grab area, as on VEED's canvas: drag the
    /// picture anywhere, at any zoom, pinch to zoom, click to play or
    /// pause, double-click to put the picture back in the middle.
    private func panHandle(width: CGFloat, height: CGFloat) -> some View {
        let clip = model.selectedClip
        return MouseHandle(
            cursor: .openHand,
            onTap: { model.togglePlay() },
            onDrag: { translation in
                guard let clip else { return }
                let from = dragPanStart ?? CGSize(width: clip.panX, height: clip.panY)
                if dragPanStart == nil { dragPanStart = from }
                dragPan = CGSize(width: VideoExporter.clampPan(from.width + translation.width / width),
                                 height: VideoExporter.clampPan(from.height + translation.height / height))
            },
            onEnd: {
                if let dragPan { model.setPan(dragPan) }
                dragPan = nil
                dragPanStart = nil
            },
            onReset: { model.setPan(.zero) },
            onMagnify: { factor in model.zoom(by: factor) }
        )
        .help("Drag to move the picture anywhere in the frame; double-click to centre it. Pinch to zoom.")
    }
    /// The subtitle's spot while it's being dragged, and where the drag began.
    @State private var dragAnchor: CaptionAnchor?
    @State private var dragStart: CGPoint?
    @State private var captionHover = false

    /// A grab area over the subtitle: drag it anywhere on the video and the
    /// export follows. A dashed outline shows on hover so it reads as
    /// movable; double-click puts it back where the style keeps it. The
    /// mouse work is AppKit's (`CaptionDragHandle`): the panel moves when
    /// its background is dragged, and only a real view can refuse that.
    private func captionHandle(for cue: TimelineCue, width: CGFloat, height: CGFloat) -> some View {
        let style = model.style
        let scale = width / VideoExporter.renderSize.width
        let pill = VideoExporter.captionFrame(for: style.display(cue.displayText), style: style,
                                              anchor: dragAnchor ?? model.captionAnchor).pill
        // Render space has its origin at the bottom; the preview's is at the top.
        let centre = CGPoint(x: pill.midX * scale, y: height - pill.midY * scale)
        let active = captionHover || dragAnchor != nil
        return RoundedRectangle(cornerRadius: style.cornerRadius * scale + 3, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(accent.opacity(active ? 0.9 : 0))
            .frame(width: pill.width * scale + 8, height: pill.height * scale + 8)
            .overlay(
                MouseHandle(
                    cursor: .openHand,
                    onHover: { captionHover = $0 },
                    onDrag: { translation in
                        let from = dragStart ?? centre
                        if dragStart == nil { dragStart = centre }
                        let to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
                        dragAnchor = CaptionAnchor(x: min(max(0, to.x / width), 1),
                                                   y: min(max(0, (height - to.y) / height), 1))
                    },
                    onEnd: {
                        model.setCaptionAnchor(dragAnchor)
                        dragAnchor = nil
                        dragStart = nil
                    },
                    onReset: { model.setCaptionAnchor(nil) }
                )
            )
            .position(centre)
            .help("Drag to move the subtitles anywhere on the video — double-click to put them back")
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: Canvas

    /// The video, centred like VEED's canvas, with the quick-action bar
    /// floating under it: the frame shape, picture zoom and the subtitle
    /// style. Auto-subtitle lives in the Subtitles panel.
    private var canvas: some View {
        GeometryReader { geo in
            let barHeight: CGFloat = 44
            let height = max(160, min(geo.size.height - barHeight - 12, (geo.size.width - 16) * 16 / 9))
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                preview(height: height)
                canvasBar
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var canvasBar: some View {
        ViewThatFits(in: .horizontal) {
            canvasBarContent(full: true)
            canvasBarContent(full: false)
        }
        .disabled(!hasClips)
        .opacity(hasClips ? 1 : 0.45)
    }

    private func canvasBarContent(full: Bool) -> some View {
        let preset = model.stylePreset
        let zoom = model.selectedClip?.zoom ?? 1
        return HStack(spacing: 2) {
            if full {
                HStack(spacing: 5) {
                    Image(systemName: "iphone").font(.system(size: 11, weight: .semibold))
                    Text("Reels · 9:16")
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 10)
                .help("Every export is 1080 × 1920 — the shape of Reels, TikTok and Shorts")
                barDivider
            }
            HStack(spacing: 2) {
                barButton("minus.magnifyingglass", help: "Zoom the picture out (or pinch on the video)") { model.zoom(by: 1 / 1.15) }
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(zoom > 1.01 ? accent : Color.white.opacity(0.7))
                    .frame(width: 34)
                barButton("plus.magnifyingglass", help: "Zoom the picture in — crops from the centre (or pinch on the video)") { model.zoom(by: 1.15) }
                barButton("rectangle.arrowtriangle.2.inward", full ? "Fill" : nil,
                          help: "Zoom just enough that the picture fills the whole 9:16 frame with no black bars") { model.zoomToFill() }
                barButton("rectangle.arrowtriangle.2.outward", full ? "Fit" : nil,
                          help: "Show the whole picture (black bars if it's landscape)") { model.setZoom(1) }
            }
            barDivider
            barButton("textformat", full ? preset.name : nil, chevron: true,
                      help: "Subtitle style: \(preset.name) · \(preset.category.rawValue) — click to change") { open(.style) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }

    private var barDivider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func barButton(_ symbol: String, _ title: String? = nil, chevron: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, title == nil ? 7 : 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Timeline

    /// How far the timeline may be pulled up on a panel this tall: the
    /// video keeps enough room to be worth looking at.
    private static func maxTimelineExtra(for height: CGFloat) -> CGFloat {
        max(0, min(260, height - 520))
    }

    /// VEED's split between the canvas and the timeline: pull it up for a
    /// taller timeline (bigger frames, a taller sound strip), down for more
    /// video. Double-click puts it back.
    private func timelineGrip(maxExtra: CGFloat) -> some View {
        let active = gripHover || gripDragStart != nil
        return ZStack {
            Rectangle()
                .fill(active ? accent : Color.white.opacity(0.12))
                .frame(height: active ? 2 : 1)
            VStack(spacing: 1.5) {
                Triangle().frame(width: 8, height: 4).rotationEffect(.degrees(180))
                Rectangle().frame(width: 12, height: 1.5)
                Rectangle().frame(width: 12, height: 1.5)
                Triangle().frame(width: 8, height: 4)
            }
            .foregroundStyle(active ? accent : Color.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay(Capsule().strokeBorder(active ? accent.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1))
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .overlay(
            MouseHandle(
                cursor: .resizeUpDown,
                onHover: { gripHover = $0 },
                onDrag: { translation in
                    let from = gripDragStart ?? CGFloat(timelineExtra)
                    if gripDragStart == nil { gripDragStart = from }
                    // Up is a negative translation, and up means taller.
                    timelineExtra = Double(min(max(0, from - translation.height), maxExtra))
                },
                onEnd: { gripDragStart = nil },
                onReset: { timelineExtra = 0 }
            )
        )
        .animation(.easeOut(duration: 0.12), value: active)
        .help("Drag up for a taller timeline, down for more video — double-click to put it back")
    }

    /// Docked along the bottom like VEED's: the transport row, then a time
    /// ruler, the subtitles track and the clips with their sound.
    private var timelineDock: some View {
        card(title: nil, trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                transportRow
                if hasClips {
                    tracks
                } else {
                    emptyRow(icon: "square.and.arrow.down",
                             text: "Your clips will line up here in the order they'll play. Press Import clips, or drop video files anywhere on this tab.")
                }
            }
        }
    }

    /// Split and the cuts on the left, play in the middle, the highlighted
    /// clip's moves on the right. Labels drop off when the panel is narrow.
    private var transportRow: some View {
        ViewThatFits(in: .horizontal) {
            transportContent(labels: true)
            transportContent(labels: false)
        }
        .disabled(!hasClips || model.phase.isBusy)
        .opacity(hasClips ? 1 : 0.4)
    }

    private func transportContent(labels: Bool) -> some View {
        HStack(spacing: 6) {
            transportButton("scissors", labels ? "Split" : nil,
                            help: "Cut the clip into two at the playhead — then remove the half you don't want") { model.splitAtPlayhead() }
            transportButton("arrow.right.to.line", labels ? "Cut before" : nil,
                            help: "Throw away everything in this clip before the playhead") { model.trimStartToPlayhead() }
            transportButton("arrow.left.to.line", labels ? "Cut after" : nil,
                            help: "Throw away everything in this clip after the playhead") { model.trimEndToPlayhead() }
            Spacer(minLength: 8)
            transportButton("backward.end.fill", nil, help: "Jump to the beginning") { model.seek(to: 0) }
            transportButton("gobackward.5", nil, help: "Go back five seconds") { model.seek(to: model.currentTime - 5) }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(accent))
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")
            transportButton("goforward.5", nil, help: "Go forward five seconds") { model.seek(to: model.currentTime + 5) }
            HStack(spacing: 4) {
                Text(VideoEditorModel.clock(model.currentTime))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                Text("/ \(VideoEditorModel.clock(model.duration))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.leading, 4)
            Spacer(minLength: 8)
            if labels, let clip = model.selectedClip {
                Label(clip.name, systemImage: "film")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
            transportButton("arrow.left", labels ? "Earlier" : nil,
                            help: "Move the highlighted clip one place earlier") { model.moveSelectedClip(by: -1) }
            transportButton("arrow.right", labels ? "Later" : nil,
                            help: "Move the highlighted clip one place later") { model.moveSelectedClip(by: 1) }
            transportButton("trash", labels ? "Remove" : nil, destructive: true,
                            help: "Take the highlighted clip out of the video (the file stays on disk)") { model.removeSelectedClip() }
        }
    }

    private func transportButton(_ symbol: String, _ title: String?, destructive: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
            }
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.9))
            .padding(.horizontal, title == nil ? 8 : 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// How much taller than its slimmest the timeline has been pulled, in
    /// points. Remembered between launches, like VEED's split.
    @AppStorage("peekyVideoTimelineExtra") private var timelineExtra: Double = 0
    @State private var gripHover = false
    @State private var gripDragStart: CGFloat?

    /// Ruler 18 + gap 4 + subtitles 22 + gap 4 + clips.
    private var tracksHeight: CGFloat { 48 + clipHeight }
    /// A clip is iMovie's shape: frames along the top, sound underneath.
    /// Pulling the timeline taller grows both, the frames faster.
    private var clipHeight: CGFloat { 84 + CGFloat(timelineExtra) }
    private var filmHeight: CGFloat { 56 + CGFloat(timelineExtra) * 0.7 }
    /// iMovie's yellow for the loud bits.
    private static let loud = Color(red: 1.0, green: 0.8, blue: 0.25)

    /// Ruler, subtitles and clips share one width, so one playhead runs
    /// through all of them and one drag scrubs anywhere.
    private var tracks: some View {
        GeometryReader { geo in
            let total = max(model.duration, 0.001)
            let width = geo.size.width
            let x = width * min(model.currentTime / total, 1)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    ruler(width: width, total: total)
                    subtitlesTrack(width: width, total: total)
                    timelineStrip
                }
                VStack(spacing: 0) {
                    Triangle().fill(accent).frame(width: 10, height: 6)
                    Rectangle().fill(accent).frame(width: 2)
                }
                .frame(height: tracksHeight)
                .offset(x: x - 5)
                .shadow(color: accent.opacity(0.7), radius: 3)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: tracksHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            // One gesture covers both a click (jump there) and a drag (scrub),
            // anywhere on the ruler or a track. The clip under the new time
            // becomes the selected clip.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.seek(to: total * min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        model.seek(to: total * min(max(value.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: tracksHeight)
    }

    /// Time along the top, like VEED's: a label every few seconds (the gap
    /// chosen so labels never crowd) and finer ticks between.
    private func ruler(width: CGFloat, total: Double) -> some View {
        let step = Self.rulerStep(for: total, width: width)
        let minor = step / 5
        return Canvas { context, size in
            let scale = size.width / total
            var i = 0
            var t = 0.0
            while t <= total + 0.0001 {
                let x = t * scale
                let isMajor = i % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 6 : 3)))
                context.stroke(tick, with: .color(Color.white.opacity(isMajor ? 0.35 : 0.18)), lineWidth: 1)
                if isMajor && x + 36 < size.width {
                    let label = Text(Self.rulerLabel(t))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                    context.draw(label, at: CGPoint(x: x + 3, y: 5), anchor: .leading)
                }
                i += 1
                t = Double(i) * minor
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        }
        .frame(width: width, height: 18)
        .allowsHitTesting(false)
    }

    /// The label spacing in seconds: the first that keeps labels 64 pt apart.
    private static func rulerStep(for total: Double, width: CGFloat) -> Double {
        let options: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return options.first { CGFloat($0 / total) * width >= 64 } ?? 600
    }

    private static func rulerLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s % 60 == 0 { return "\(s / 60)m" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// VEED's subtitles lane: a bar the length of the video with a block
    /// for every line, the live one lit.
    private func subtitlesTrack(width: CGFloat, total: Double) -> some View {
        let cues = model.project?.timelineCues ?? []
        let now = model.currentTime
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cues.isEmpty ? Color.white.opacity(0.05) : accent.opacity(0.14))
            Canvas { context, size in
                let scale = size.width / total
                for cue in cues {
                    let live = now >= cue.start && now < cue.end
                    let rect = CGRect(x: cue.start * scale, y: 5,
                                      width: max(2, (cue.end - cue.start) * scale - 1), height: size.height - 10)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(accent.opacity(live ? 0.95 : 0.5)))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "captions.bubble.fill").font(.system(size: 9))
                Text(cues.isEmpty ? "No subtitles yet — press Auto-subtitle" : "Subtitles")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(Color.white.opacity(cues.isEmpty ? 0.45 : 0.95))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(.leading, 5)
        }
        .frame(width: width, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(cues.isEmpty ? Color.white.opacity(0.1) : accent.opacity(0.35), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    /// The clips in play order, each with its sound drawn inside.
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

                // Seams that can be healed: a faint stitch mark always, and
                // a Rejoin pill when the mouse rests near one.
                if let project = model.project {
                    ForEach(healableSeams(in: project), id: \.self) { index in
                        let seamX = geo.size.width * project.clipStarts[index + 1] / total
                        let near = hoverX.map { abs($0 - seamX) < 16 } ?? false
                        if near {
                            rejoinPill(index: index)
                                .position(x: seamX, y: clipHeight / 2)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        } else {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                                .position(x: seamX, y: clipHeight / 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: clipHeight)
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
        }
        .frame(height: clipHeight)
    }

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
                VStack(spacing: 0) {
                    filmstrip(for: clip, width: width)
                    waveform(for: clip, width: width)
                }
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
            .frame(width: width, height: clipHeight, alignment: .topLeading)
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

    /// iMovie's filmstrip: one frame per tile along the clip, each the
    /// frame from that moment, at the picture's own shape.
    @ViewBuilder
    private func filmstrip(for clip: EditClip, width: CGFloat) -> some View {
        let height = filmHeight
        if let frames = model.filmstrips[clip.source.path], let first = frames.first {
            let tileWidth = max(12, height * CGFloat(first.width) / CGFloat(max(1, first.height)))
            Canvas { context, size in
                var x: CGFloat = 0
                while x < size.width {
                    let visible = min(tileWidth, size.width - x)
                    let offset = clip.duration * Double((x + visible / 2) / size.width)
                    if let frame = Filmstrip.frame(in: frames, at: clip.inPoint + offset, sourceDuration: clip.sourceDuration) {
                        var tile = context
                        tile.clip(to: Path(CGRect(x: x, y: 0, width: visible, height: height)))
                        tile.draw(Image(decorative: frame, scale: 1), in: CGRect(x: x, y: 0, width: tileWidth, height: height))
                    }
                    x += tileWidth
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }

    /// iMovie's sound strip: loudness rises from the bottom in blue and the
    /// loudest moments tip over into yellow. What's already played is
    /// brighter so the playhead has a trail.
    @ViewBuilder
    private func waveform(for clip: EditClip, width: CGFloat) -> some View {
        let height = clipHeight - filmHeight
        let step: CGFloat = 2
        let count = max(2, Int(width / step))
        if let raw = model.waveformBars(for: clip, count: count) {
            let bars = smoothed(raw)
            let played = playedFraction(of: clip)
            Canvas { context, size in
                let amp = size.height - 3
                var shape = Path()
                shape.move(to: CGPoint(x: 0, y: size.height))
                for (i, level) in bars.enumerated() {
                    shape.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - max(1.5, CGFloat(level) * amp)))
                }
                shape.addLine(to: CGPoint(x: CGFloat(bars.count - 1) * step, y: size.height))
                shape.closeSubpath()
                let loudLine = size.height - 0.72 * amp

                func paint(_ ctx: GraphicsContext, body: Color, cap: Color) {
                    ctx.fill(shape, with: .color(body))
                    var caps = ctx
                    caps.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: loudLine)))
                    caps.fill(shape, with: .color(cap))
                }
                paint(context, body: accent.opacity(0.55), cap: Self.loud.opacity(0.7))
                if played > 0 {
                    var trail = context
                    trail.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * played, height: size.height)))
                    paint(trail, body: accent.opacity(0.95), cap: Self.loud)
                }
            }
            .frame(width: width, height: height)
            .background(accent.opacity(0.12))
            .allowsHitTesting(false)
        } else if model.waveforms[clip.source.path] == nil {
            HStack {
                Spacer()
                ProgressView().controlSize(.mini).opacity(0.5)
                Spacer()
            }
            .frame(width: width, height: height)
        } else {
            Color.clear.frame(width: width, height: height)
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

    // MARK: Control bits

    private func controlGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.4))
            // Wraps when the panel is narrow instead of pushing it wider.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66, maximum: 66), spacing: 6)], alignment: .leading, spacing: 6) {
                content()
            }
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

    // MARK: Panels

    /// A tool's panel beside the rail: a card that takes the full height
    /// and scrolls inside itself.
    private func toolCard<Content: View>(title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        card(title: title, trailing: trailing, content: content)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The takes in play order; click one to jump to it.
    private var clipsPanel: some View {
        let clips = model.project?.clips ?? []
        return toolCard(title: "CLIPS", trailing: clips.isEmpty ? nil : "\(clips.count) · \(VideoEditorModel.clock(model.duration))") {
            VStack(alignment: .leading, spacing: 10) {
                pillButton("Import clips", icon: "square.and.arrow.down") { model.chooseClips() }
                    .help("Add more takes or screen recordings — or drop files anywhere on this tab")
                if clips.isEmpty {
                    emptyRow(icon: "square.and.arrow.down", text: "Your clips will line up here in the order they'll play.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(Array(clips.enumerated()), id: \.element.id) { item in
                                clipRow(item.element, index: item.offset)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Divider().overlay(Color.white.opacity(0.08))
                    controlGroup("HIGHLIGHTED CLIP") {
                        tile("arrow.left", "Earlier", help: "Move the highlighted clip one place earlier") { model.moveSelectedClip(by: -1) }
                        tile("arrow.right", "Later", help: "Move the highlighted clip one place later") { model.moveSelectedClip(by: 1) }
                        tile("trash", "Remove", help: "Take the highlighted clip out of the video (the file stays on disk)", destructive: true) { model.removeSelectedClip() }
                    }
                    .disabled(model.selectedClip == nil || model.phase.isBusy)
                }
            }
        }
    }

    private func clipRow(_ clip: EditClip, index: Int) -> some View {
        let selected = clip.id == model.selectedClipID
        return Button { model.selectClip(clip.id) } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(selected ? accent : Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text("\(VideoEditorModel.clock(clip.inPoint))–\(VideoEditorModel.clock(clip.outPoint)) · \(VideoEditorModel.clock(clip.duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer(minLength: 4)
                if !clip.cues.isEmpty {
                    Image(systemName: "captions.bubble.fill").font(.system(size: 10)).foregroundStyle(accent.opacity(0.9))
                }
                if clip.zoom > 1.01 {
                    Text(String(format: "%.1f×", clip.zoom))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(clip.source.path)\nClick to jump to this clip")
    }

    /// The cuts and the picture zoom, with the words that explain them.
    private var trimPanel: some View {
        let zoom = model.selectedClip?.zoom ?? 1
        return toolCard(title: "TRIM", trailing: model.selectedClip.map { "\($0.name) · \(VideoEditorModel.clock($0.duration))" }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Press Play and stop where you want to cut. Everything here works on the highlighted clip, at the playhead.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                controlGroup("CUT AT THE PLAYHEAD") {
                    tile("scissors", "Split", help: "Cut the clip into two at the playhead — then remove the half you don't want") { model.splitAtPlayhead() }
                    tile("arrow.right.to.line", "Cut before", help: "Throw away everything in this clip before the playhead") { model.trimStartToPlayhead() }
                    tile("arrow.left.to.line", "Cut after", help: "Throw away everything in this clip after the playhead") { model.trimEndToPlayhead() }
                }
                controlGroup("PICTURE ZOOM  \(String(format: "%.1f×", zoom))") {
                    tile("minus.magnifyingglass", "Out", help: "Zoom out (or pinch on the video)") { model.zoom(by: 1 / 1.15) }
                    tile("plus.magnifyingglass", "In", help: "Zoom in — crops from the centre (or pinch on the video)") { model.zoom(by: 1.15) }
                    tile("rectangle.arrowtriangle.2.inward", "Fill", help: "Zoom just enough that the picture fills the whole 9:16 frame with no black bars") { model.zoomToFill() }
                    tile("rectangle.arrowtriangle.2.outward", "Fit", help: "Show the whole picture (black bars if it's landscape)") { model.setZoom(1) }
                }
                Text("The bars on the timeline are the sound: tall where you're talking, flat in the gaps — cut in a gap. Click anywhere on the timeline to jump there, or drag to scrub. Two halves of the same take show a Rejoin pill on their seam.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!hasClips || model.phase.isBusy)
        }
    }

    /// VEED's Subtitles panel, at home in Peeky: pick the spoken language,
    /// optionally a translation, press the green button, then fix any
    /// words in the list.
    private var subtitlesPanel: some View {
        let count = model.project?.timelineCues.count ?? 0
        return toolCard(title: "SUBTITLES", trailing: hasCaptions ? "\(count) line\(count == 1 ? "" : "s")" : nil) {
            VStack(alignment: .leading, spacing: 12) {
                if hasClips {
                    subtitleSettings
                } else {
                    emptyRow(icon: "captions.bubble",
                             text: "Import clips first — then Peeky can transcribe them into subtitles.")
                }
                if let cues = model.project?.timelineCues, !cues.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    styleRow
                    Text("Click a time to jump there; click words to fix them.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(cues) { cue in cueRow(cue) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// Every look on VEED's shelves, with the current one marked.
    private var stylePanel: some View {
        let preset = model.stylePreset
        return toolCard(title: "SUBTITLE STYLE", trailing: "\(preset.name) · \(preset.category.rawValue)") {
            styleShelf
        }
    }

    /// The finished video, and where the last one went.
    private var exportPanel: some View {
        toolCard(title: "EXPORT", trailing: nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saves an MP4 at 1080 × 1920 with the subtitles burned in, plus the .srt and a transcript, in this project's exports folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                pillButton("Export video", icon: "square.and.arrow.up", prominent: true) { model.export() }
                    .disabled(!hasClips || model.phase.isBusy)
                    .opacity(hasClips ? 1 : 0.45)
                if case .exporting(let progress) = model.phase {
                    ProgressView(value: progress).tint(accent)
                }
                if !hasCaptions && hasClips {
                    emptyRow(icon: "captions.bubble",
                             text: "No subtitles yet — you can export without them, or press Auto-subtitle first.")
                }
                if let url = model.lastExport {
                    Divider().overlay(Color.white.opacity(0.08))
                    sectionLabel("LAST EXPORT")
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        pillButton("Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        pillButton("Open", icon: "play.rectangle") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    // MARK: Subtitle styles

    /// The current look, with a way in to VEED's style shelf.
    private var styleRow: some View {
        let preset = model.stylePreset
        return HStack(spacing: 10) {
            styleTile(preset, selected: false, compact: true)
                .frame(width: 92, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtitle style")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(preset.name) · \(preset.category.rawValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button("Change") { open(.style) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(accent.opacity(0.14)))
                .help("Pick a different look for every subtitle")
        }
    }

    /// Every preset, on VEED's shelves. Click one and the video, the export
    /// and the list all switch at once.
    private var styleShelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SubtitleStylePreset.Category.allCases) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(category.presets) { preset in
                                Button { model.setSubtitleStyle(preset) } label: {
                                    styleTile(preset, selected: preset == model.stylePreset, compact: false)
                                        .aspectRatio(1.75, contentMode: .fit)
                                }
                                .buttonStyle(.plain)
                                .help(preset.name)
                            }
                        }
                    }
                }
                Text("Styles that colour a word follow your voice, word by word.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: .infinity)
    }

    private func styleTile(_ preset: SubtitleStylePreset, selected: Bool, compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(Color(white: 0.62))
            CaptionLayerView(text: SubtitleStylePreset.sampleText, highlight: preset.sampleHighlight,
                             style: preset.style, placement: .fitted)
                .allowsHitTesting(false)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, accent)
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .strokeBorder(selected ? accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    /// The VEED-green action, "Auto-subtitle in English": a pill the size
    /// of the header's Import and Export buttons, not a full-width bar.
    private var autoSubtitleButton: some View {
        let lime = Color(red: 0.78, green: 0.95, blue: 0.40)
        let language = SubtitleLanguages.name(of: model.spokenLocale)
        let title = hasCaptions ? "Re-subtitle in \(language)" : "Auto-subtitle in \(language)"
        return Button { model.generateCaptions() } label: {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lime))
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

/// The mouse side of a grab area on the preview — the subtitle, or the
/// picture itself. AppKit asks the view under the mouse whether a drag
/// should move the window (the panel says yes for its background), so
/// this view says no and tracks the drag itself, reporting in window
/// points so its own movement mid-drag doesn't matter.
private struct MouseHandle: NSViewRepresentable {
    /// Shown over the area, or nil for the plain arrow.
    var cursor: NSCursor? = nil
    var onHover: ((Bool) -> Void)? = nil
    /// A click that didn't turn into a drag.
    var onTap: (() -> Void)? = nil
    /// How far the mouse has moved since it went down, in view points
    /// (y grows downwards, as in SwiftUI).
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    /// A double-click.
    var onReset: (() -> Void)? = nil
    /// A trackpad pinch, as the factor to multiply the zoom by.
    var onMagnify: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        update(handle)
        return handle
    }

    func updateNSView(_ handle: Handle, context: Context) { update(handle) }

    private func update(_ handle: Handle) {
        handle.cursor = cursor
        handle.onHover = onHover
        handle.onTap = onTap
        handle.onDrag = onDrag
        handle.onEnd = onEnd
        handle.onReset = onReset
        handle.onMagnify = onMagnify
    }

    final class Handle: NSView {
        var cursor: NSCursor? {
            didSet { if cursor !== oldValue { window?.invalidateCursorRects(for: self) } }
        }
        var onHover: ((Bool) -> Void)?
        var onTap: (() -> Void)?
        var onDrag: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?
        var onReset: (() -> Void)?
        var onMagnify: ((CGFloat) -> Void)?
        private var origin: NSPoint?
        private var moved = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // AppKit owns the cursor rectangle, so an area that vanishes under
        // the mouse (a subtitle whose line ends) can't leave a hand behind.
        override func resetCursorRects() {
            if let cursor { addCursorRect(visibleRect, cursor: cursor) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                origin = nil
                onReset?()
                return
            }
            origin = event.locationInWindow
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let now = event.locationInWindow
            // Window coordinates grow upwards; the preview's grow downwards.
            let delta = CGSize(width: now.x - origin.x, height: origin.y - now.y)
            // A twitch during a click isn't a drag.
            if !moved, abs(delta.width) < 2, abs(delta.height) < 2 { return }
            moved = true
            onDrag?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onEnd?() } else if origin != nil { onTap?() }
            origin = nil
            moved = false
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(1 + event.magnification)
        }
    }
}

/// The preview player without AVKit's own controls; the transport is ours.
/// The clip under the playhead's zoom is a scale on the player's layer:
/// a zoom on the same clip glides there, a cut to another clip is a hard
/// switch, and the player itself is never rebuilt for either.
private struct VideoEditorSurface: NSViewRepresentable {
    let player: AVPlayer
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var clipID: UUID? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var clipID: UUID?
    }

    func makeNSView(context: Context) -> ZoomingPlayerView {
        let view = ZoomingPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.set(zoom: zoom, pan: pan, animated: false)
        context.coordinator.clipID = clipID
        return view
    }

    func updateNSView(_ view: ZoomingPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        let sameClip = context.coordinator.clipID == clipID
        context.coordinator.clipID = clipID
        view.set(zoom: zoom, pan: pan, animated: sameClip)
    }
}

/// An AVPlayerView that scales its picture about the centre and shifts it
/// by the pan — the same crop the export makes. A zoom glides; a pan
/// (the user's own drag) follows the mouse as it is.
private final class ZoomingPlayerView: AVPlayerView {
    private var zoom: CGFloat = 1
    private var pan: CGSize = .zero

    func set(zoom target: CGFloat, pan newPan: CGSize, animated: Bool) {
        let clamped = max(0.1, target)
        let zoomChanged = abs(clamped - zoom) > 0.0005
        let panChanged = abs(newPan.width - pan.width) > 0.00005 || abs(newPan.height - pan.height) > 0.00005
        guard zoomChanged || panChanged else { return }
        zoom = clamped
        pan = newPan
        guard let layer else { return }
        let to = transform(for: zoom)
        // Start from wherever the picture is *now*, so a second click
        // mid-glide carries on rather than snapping.
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        if animated && zoomChanged {
            let glide = CABasicAnimation(keyPath: "transform")
            glide.fromValue = from
            glide.toValue = to
            glide.duration = 0.32
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(glide, forKey: "zoom")
        } else {
            layer.removeAnimation(forKey: "zoom")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // The centre moved with the size; re-aim the scale at it, silently.
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform(for: zoom)
        CATransaction.commit()
    }

    private func transform(for zoom: CGFloat) -> CATransform3D {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // The pan is "right and down"; this layer's y may grow upwards.
        let down: CGFloat = isFlipped ? 1 : -1
        var t = CATransform3DMakeTranslation(centre.x + pan.width * bounds.width,
                                             centre.y + down * pan.height * bounds.height, 0)
        t = CATransform3DScale(t, zoom, zoom, 1)
        return CATransform3DTranslate(t, -centre.x, -centre.y, 0)
    }
}
