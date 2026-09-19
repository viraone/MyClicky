import AVKit
import SwiftUI

/// The Peeky Video tab. Left: a 9:16 preview with the live caption drawn
/// over it. Right: the timeline, transport and edit buttons, and the
/// captions list where wording gets fixed. Everything mechanical is a
/// button; choosing takes and words stays with the user.
struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    let accent: Color
    @State private var newProjectName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasProject {
                toolbar
                if let line = statusLine { line }
                HStack(alignment: .top, spacing: 14) {
                    preview
                    VStack(alignment: .leading, spacing: 10) {
                        timeline
                        transport
                        captions
                    }
                }
            } else {
                start
            }
        }
        .font(.system(size: 13, design: .monospaced))
    }

    // MARK: Start

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Peeky Video", systemImage: "film")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            Text("Import your takes, trim them in order, generate captions, fix the words, export 1080 × 1920 for Reels, TikTok and your portfolio.")
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                button("Import clips…", icon: "square.and.arrow.down", prominent: true) { model.chooseClips() }
                Text("or drop video files anywhere on this tab")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                TextField("Or name a project first — e.g. Notion review", text: $newProjectName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .frame(maxWidth: 460)
                    .onSubmit(createProject)
                button("Create project", icon: "plus", action: createProject)
                    .opacity(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.55 : 1)
            }
            Text("Importing straight away names the project after your first clip; you can rename the folder later.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            if !model.recentProjects.isEmpty {
                Text("RECENT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.45))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.recentProjects, id: \.self) { folder in
                            Button { model.open(folder: folder) } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(folder.lastPathComponent)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if case .failed(let message) = model.phase {
                Text(message).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.newProject(named: name)
        newProjectName = ""
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.closeProject() } label: {
                Label("Projects", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            Text(model.project?.name ?? "")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Button { model.revealProject() } label: { Image(systemName: "folder") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
                .help("Show the project folder in Finder")
            Spacer()
            button("Import clips", icon: "square.and.arrow.down") { model.chooseClips() }
            button("Captions", icon: "captions.bubble") { model.generateCaptions() }
                .disabled(model.project?.clips.isEmpty ?? true)
            button("Export 1080×1920", icon: "square.and.arrow.up", prominent: true) { model.export() }
                .disabled(model.project?.clips.isEmpty ?? true)
        }
        .disabled(model.phase.isBusy)
    }

    private var statusLine: AnyView? {
        switch model.phase {
        case .importing(let i, let n):
            return AnyView(progressLine("Reading clip \(i) of \(n)…", value: nil))
        case .transcribing(let name, let i, let n):
            return AnyView(progressLine("Listening to \(name) (\(i) of \(n))…", value: nil))
        case .exporting(let p):
            return AnyView(progressLine("Exporting… \(Int(p * 100))%", value: p))
        case .exported(let url):
            return AnyView(HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain).foregroundStyle(accent)
                Spacer()
                Button { model.dismissPhase() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            })
        case .failed(let message):
            return AnyView(HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button { model.dismissPhase() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            })
        case .idle:
            guard let note = model.note else { return nil }
            return AnyView(Text(note).foregroundStyle(.white.opacity(0.6)).lineLimit(1))
        }
    }

    private func progressLine(_ text: String, value: Double?) -> some View {
        HStack(spacing: 10) {
            if let value {
                ProgressView(value: value).frame(width: 140)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Spacer()
        }
        .tint(accent)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack(alignment: .bottom) {
            VideoEditorSurface(player: model.player)
            if model.project?.clips.isEmpty ?? true {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 28))
                    Text("Drop takes here\nor Import clips").multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let cue = model.currentCue {
                Text(cue.text)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.65)))
                    .padding(.horizontal, 20)
                    // Same spot as the burned-in caption: its centre 30% up.
                    .alignmentGuide(.bottom) { d in d[VerticalAlignment.center] }
                    .offset(y: -previewHeight * model.style.centreFromBottom)
            }
        }
        .frame(width: previewHeight * 9 / 16, height: previewHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private let previewHeight: CGFloat = 440

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let total = max(model.duration, 0.001)
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        if let project = model.project {
                            ForEach(project.clips) { clip in
                                clipBlock(clip, width: max(4, geo.size.width * clip.duration / total - 2))
                            }
                        }
                    }
                    if model.duration > 0 {
                        Rectangle()
                            .fill(accent)
                            .frame(width: 2)
                            .offset(x: geo.size.width * min(model.currentTime / total, 1))
                            .shadow(color: accent.opacity(0.8), radius: 3)
                    }
                }
                .frame(height: 54)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.seek(to: total * min(max(value.location.x / geo.size.width, 0), 1))
                        }
                )
            }
            .frame(height: 54)
            HStack {
                Text(VideoEditorModel.clock(model.currentTime))
                    .foregroundStyle(accent)
                Text("/ \(VideoEditorModel.clock(model.duration))")
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let clip = model.selectedClip {
                    Text("\(clip.name) · \(VideoEditorModel.clock(clip.inPoint))–\(VideoEditorModel.clock(clip.outPoint))")
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func clipBlock(_ clip: EditClip, width: CGFloat) -> some View {
        let selected = clip.id == model.selectedClipID
        return Button { model.selectClip(clip.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(VideoEditorModel.clock(clip.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                if !clip.cues.isEmpty {
                    Image(systemName: "captions.bubble.fill").font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: width, height: 54, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? accent.opacity(0.35) : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? accent : Color.white.opacity(0.15), lineWidth: 1)
            )
            .clipped()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help("\(clip.source.path)")
    }

    private var transport: some View {
        HStack(spacing: 6) {
            iconButton(model.isPlaying ? "pause.fill" : "play.fill", help: model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
            iconButton("backward.end.fill", help: "Start") { model.seek(to: 0) }
            iconButton("gobackward.5", help: "Back 5s") { model.seek(to: model.currentTime - 5) }
            iconButton("goforward.5", help: "Forward 5s") { model.seek(to: model.currentTime + 5) }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.2))
            iconButton("scissors", help: "Split the clip at the playhead") { model.splitAtPlayhead() }
            iconButton("arrow.right.to.line", help: "Trim the clip's start to the playhead") { model.trimStartToPlayhead() }
            iconButton("arrow.left.to.line", help: "Trim the clip's end to the playhead") { model.trimEndToPlayhead() }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.2))
            iconButton("arrow.left", help: "Move the selected clip earlier") { model.moveSelectedClip(by: -1) }
            iconButton("arrow.right", help: "Move the selected clip later") { model.moveSelectedClip(by: 1) }
            iconButton("trash", help: "Remove the selected clip") { model.removeSelectedClip() }
            Spacer()
        }
        .disabled(model.project?.clips.isEmpty ?? true)
    }

    // MARK: Captions

    private var captions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CAPTIONS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let count = model.project?.timelineCues.count, count > 0 {
                    Text("\(count)").foregroundStyle(.white.opacity(0.4)).font(.system(size: 11, design: .monospaced))
                }
            }
            if let cues = model.project?.timelineCues, !cues.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(cues) { cue in
                            cueRow(cue)
                        }
                    }
                }
            } else {
                Text(model.project?.clips.isEmpty ?? true
                     ? "Import clips, then press Captions."
                     : "Press Captions to transcribe every take and lay captions on the timeline. Then fix any wording here.")
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cueRow(_ cue: TimelineCue) -> some View {
        let live = model.currentTime >= cue.start && model.currentTime < cue.end
        return HStack(alignment: .center, spacing: 8) {
            Button { model.seek(to: cue.start) } label: {
                Text(VideoEditorModel.clock(cue.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(live ? accent : .white.opacity(0.5))
                    .frame(width: 58, alignment: .leading)
            }
            .buttonStyle(.plain)
            TextField("", text: Binding(
                get: { cue.text },
                set: { model.setCueText(cue.id, $0) }
            ))
            .textFieldStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            Button { model.removeCue(cue.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.35))
            .help("Remove this caption")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(live ? accent.opacity(0.18) : Color.white.opacity(0.05))
        )
    }

    // MARK: Bits

    private func button(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? accent.opacity(0.25) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(prominent ? accent.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .help(help)
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
