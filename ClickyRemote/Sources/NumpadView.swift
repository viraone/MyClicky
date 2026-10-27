import SwiftUI
import AudioToolbox
import Photos
import PhotosUI

/// A 22-key numeric keypad skinned like a Super Nintendo console.
/// Key "0" toggles Peeky on the Mac (show / collapse); "4" records a question;
/// "1" opens Capture + Dictate, "2" starts a region capture, "3" records dictation.
struct NumpadView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var client = ClickyClient()
    @StateObject private var recorder = SpeechRecorder()
    @State private var statusText = "Tap PEEKY to open it on your Mac (tap again to hide)"
    @State private var permissionDenied = false
    /// Short-lived toast over the whole console — used for warnings that fire
    /// while a recording is running, when the status line isn't visible.
    @State private var recordingNotice: String?
    @State private var noticeOK = false
    @State private var recordingNoticeTask: Task<Void, Never>?
    /// True after tapping "1"/"3": speech goes to the Mac clipboard, not a question.
    @State private var dictateMode = false
    /// Which target the current recording is for.
    enum RecordTarget { case ask, dictate, talk, doc }
    @State private var recordTarget: RecordTarget = .ask
    /// Quick-save state: send a photo straight to the Mac's Desktop.
    @State private var desktopPickerShown = false
    @State private var desktopPick: PhotosPickerItem?
    @State private var desktopCameraShown = false
    @State private var savingToDesktop = false
    /// Shopify's second screen: a live table read from Chrome. `shopifyParent`
    /// is the sidebar tile that was tapped (which picks the tab strip);
    /// `shopifySection` is the tab currently showing.
    @State private var shopifyTableShown = false
    @State private var shopifyParent = "Orders"
    @State private var shopifySection = "Orders"

    /// Which "cartridge" is loaded: the desktop remote, Peeky Code, or an app remote.
    @State private var mode: RemoteMode = .remote
    /// Documentary answers are silent on the phone unless the user opts in.
    @AppStorage("documentaryReadoutEnabled") private var documentaryReadoutEnabled = false
    /// What the Peeky Video dial moves: the playhead, or one edge of the selected clip.
    enum JogMode: String, CaseIterable {
        case scrub = "Playhead", trimStart = "Trim start", trimEnd = "Trim end"
        var icon: String {
            switch self {
            case .scrub: "playhead"
            case .trimStart: "arrow.right.to.line"
            case .trimEnd: "arrow.left.to.line"
            }
        }
    }
    @State private var jogMode: JogMode = .scrub
    /// Ten frames per detent instead of one, for covering ground.
    @State private var jogCoarse = false
    /// The pending single-tap Open, held back until the double-tap window
    /// closes; a second tap cancels it and sends Quit instead.
    @State private var youtubeOpenTap: DispatchWorkItem?
    /// Where the Doc scrubber is being dragged to; sent as one SEEK on release.
    @State private var docScrub: Double?

    enum RemoteMode: String, CaseIterable {
        /// The keypad. Talk isn't a mode: its button rides in the corner of
        /// every pad (see `cornerTalkButton`), so it needs no cartridge.
        case remote = "Mobile Peeky"
        case code = "PEEKY CODE"
        case doc = "PEEKY DOC"
        case video = "PEEKY VIDEO"
        case shopify = "SHOPIFY"
        case youtube = "YOUTUBE"
        case keynote = "KEYNOTE"
        /// Records the class mic that is plugged into the Mac.
        case classRec = "CLASS"

        var icon: String {
            switch self {
            case .remote: ""
            case .code: "chevron.left.forwardslash.chevron.right"
            case .doc: "film.stack"
            case .video: "film"
            case .shopify: "storefront.fill"
            case .youtube: "play.rectangle.fill"
            case .keynote: "play.rectangle.on.rectangle.fill"
            case .classRec: "waveform.circle.fill"
            }
        }

        /// One-word label for the portrait strip, where there's no room for
        /// "Mobile Peeky".
        var shortName: String {
            switch self {
            case .remote: "PEEKY"
            case .code: "PEEKY CODE"
            case .doc: "DOC"
            case .video: "VIDEO"
            default: rawValue
            }
        }

        var accent: Color {
            switch self {
            case .remote: Snes.purple
            case .code: Snes.red
            case .doc: Snes.doc
            case .video: Snes.video
            case .shopify: Snes.shopify
            case .youtube: Snes.youtube
            case .keynote: Snes.keynote
            case .classRec: Snes.red
            }
        }

        var welcome: String {
            switch self {
            case .remote: "Tap PEEKY to move it to the corner, or ON to bring it back"
            case .code: "Peeky Code mode — Terminal and Enter control Peeky on your Mac"
            case .doc: "Peeky Doc — play a documentary, then Ask Peeky about the moment on screen"
            case .video: "Peeky Video — play, cut and export the project open on your Mac; spin the dial to move frame by frame"
            case .shopify: "Shopify mode — tap a section to open it in the admin tab in Chrome on your Mac"
            case .youtube: "YouTube mode — buttons control the YouTube tab open in your browser"
            case .keynote: "Keynote clicker — the ring steps through slides, the centre plays / advances, Home brings Keynote up on your Mac"
            case .classRec: "Class recorder — tap the red button to record the mic plugged into your Mac, tap again to save"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // The app is locked to landscape, but the layout still keys off
            // the actual shape so it degrades sensibly on iPad split view.
            if geo.size.height > geo.size.width {
                VStack(spacing: 10) {
                    header
                        .padding(.top, 8)
                    modeStrip
                    pad
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        // Sits below the top edge rather than flush against it,
                        // so the status line reads as its own thing instead of
                        // running into the mode column.
                        header
                            .padding(.top, 40)
                        modeTabs
                            .frame(maxHeight: .infinity)
                        Text("SUPER PEEKY\nENTERTAINMENT SYSTEM")
                            .font(.system(size: 8, weight: .heavy, design: .monospaced).italic())
                            .kerning(1)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Snes.text.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    pad
                        .frame(width: geo.size.width * 0.78)
                }
            }
        }
        .padding(10)
        .background(consoleBackground.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let notice = recordingNotice {
                toast(notice)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: recordingNotice)
        .task {
            client.onMacMessage = { line in
                // Stop pressed on the Mac panel: drop the recording, send nothing.
                if line == "STOP", recorder.isListening {
                    Task {
                        _ = await recorder.stop()
                        statusText = "Stopped — nothing sent"
                    }
                }
            }
            client.onShopifyStatus = { message, ok in
                guard mode == .shopify else { return }
                statusText = (ok ? "✓ " : "⚠︎ ") + message
                if !ok { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            }
            client.onSavePhotoStatus = { message, ok in
                statusText = (ok ? "✓ " : "⚠︎ ") + message
                showNotice(ok ? "Added to VIRADETH_RESUME on your Desktop" : message,
                           ok: ok, seconds: ok ? 2.4 : 3.5)
            }
            // ENTIRE SCREEN: a black toast, not a spoken status — the shot is
            // already described by the key and the toast is enough.
            client.onScreenshotStatus = { message, ok in
                statusText = (ok ? "✓ " : "⚠︎ ") + message
                showNotice(message, ok: ok, seconds: ok ? 2.4 : 3.5)
            }
            client.start()
            permissionDenied = !(await SpeechRecorder.requestPermissions())
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from suspension is the one moment the connection is
            // reliably stale, and the one moment nothing used to check — iOS
            // tears the socket down while the app sleeps and the app wakes up
            // still believing it's linked.
            guard phase == .active else { return }
            client.resume()
        }
        .onChange(of: client.status) { _, status in
            if status == .connected, mode == .doc {
                client.setDocumentaryReadout(documentaryReadoutEnabled)
            }
            // The Mac went away mid-recording (relaunched, slept, dropped off
            // Wi-Fi). Left alone, the recorder keeps banking words and the next
            // TALK tap — a *stop* — would fire the whole stale transcript at a
            // freshly connected Mac as one command. Observed live: an old
            // "open Jason Katz … undo that" replayed on tap, before a word was
            // said. Drop the recording instead.
            guard status != .connected, recorder.isListening else { return }
            Task {
                _ = await recorder.stop()
                statusText = "Lost Peeky mid-recording — nothing sent. Tap again once it's back."
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        .onChange(of: client.talkMessage) { _, message in
            // The Mac's replies to a spoken command show up in the status line.
            guard !message.isEmpty else { return }
            statusText = message
        }
        .onChange(of: client.youtubeCollapsed) { _, collapsed in
            guard mode == .youtube else { return }
            statusText = collapsed ? "YouTube — browser minimized" : "YouTube — browser restored"
        }
    }

    // MARK: - Mode tabs (cartridge selector)

    /// Shared portrait/landscape order. Keynote sits where Peeky Code used
    /// to; Peeky Code is temporarily off and parked at the end — delete the
    /// `.disabled`/`.opacity` in `stripButton` and move it back up to
    /// bring it back.
    private var wheelEntries: [String] {
        [
            RemoteMode.remote.rawValue,
            RemoteMode.keynote.rawValue,
            RemoteMode.classRec.rawValue,
            RemoteMode.shopify.rawValue,
            "REFRESH",
            RemoteMode.video.rawValue,
            RemoteMode.doc.rawValue,
            RemoteMode.youtube.rawValue,
            RemoteMode.code.rawValue,
        ]
    }

    /// The active mode's pad, with the corner Talk button and any pending
    /// confirm/choice card layered on. Shared by both orientations.
    private var pad: some View {
        Group {
            switch mode {
            case .remote: keypad
            case .code: keypad
            case .doc: docPad
            case .video: videoPad
            case .shopify: shopifyPad
            case .youtube: youtubePad
            case .keynote: keynotePad
            case .classRec: classRecPad
            }
        }
        // Talk rides along in the corner of the remaining pads — the keypad
        // has a full-size TALK key of its own, and Shopify is kept clear so
        // the whole bottom edge belongs to its section grid.
        // `safeAreaInset` rather than an overlay: it reserves its own
        // space instead of sitting on top of a key or tile and
        // swallowing taps meant for what's underneath.
        .safeAreaInset(edge: .trailing, alignment: .bottom, spacing: 6) {
            // The trailing padding is what holds it off the right
            // edge — raise it to move Talk further left, lower it to
            // push it back toward the corner.
            if mode != .remote && mode != .code && mode != .doc && mode != .video
                && mode != .keynote && mode != .classRec && mode != .shopify {
                cornerTalkButton.padding(.trailing, 44)
            }
        }
        // A confirmation is the one thing that must not be missed —
        // it used to live on the Talk pad, so it now covers whichever
        // pad is up until it's answered.
        .overlay {
            if let confirm = client.pendingConfirm {
                // Edge to edge: nothing of the pad underneath should show.
                confirmView(confirm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else if let choice = client.pendingChoice {
                AnyView(choiceView(choice))
                    .padding(10)
                    .background(Snes.bodyDark.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.pendingConfirm?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.pendingChoice?.id)
    }

    /// Portrait mode picker: one row, Weather-app style — icon over a short
    /// label for every mode, plus REFRESH, evenly spaced across a single
    /// translucent card. The active mode is lit in its own colour.
    private var modeStrip: some View {
        // Scrolls sideways rather than squeezing every cartridge into the
        // screen's width: eight across left each icon about 48pt wide and shrank
        // the labels to 7pt. At a fixed 80pt each they are legible, and the row
        // slides to reach the ones past the edge.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(wheelEntries, id: \.self) { entry in
                    stripButton(entry)
                        .frame(width: 80)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Snes.bodyDark.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func stripButton(_ entry: String) -> some View {
        if entry == "REFRESH" {
            stripItem(icon: "arrow.clockwise", title: "REFRESH", accent: Snes.green, selected: false) {
                client.browserReload()
                statusText = "Refreshing the page on your Mac"
            }
        } else if let m = RemoteMode(rawValue: entry) {
            stripItem(icon: m.icon.isEmpty ? "sparkles" : m.icon, title: m.shortName, accent: m.accent,
                      selected: mode == m) {
                selectMode(m)
            }
            // Temporarily off at the user's request; delete this
            // modifier to bring Peeky Code back.
            .disabled(m == .code)
            .opacity(m == .code ? 0.35 : 1)
        }
    }

    private func stripItem(icon: String, title: String, accent: Color, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 60, height: 60)
                    .foregroundStyle(.white)
                    .background(
                        Circle()
                            .fill(LinearGradient(
                                colors: selected ? [accent.lighter(0.25), accent]
                                    : [accent.lighter(0.15), accent.darker(0.05)],
                                startPoint: .top, endPoint: .bottom))
                            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.75 : 0.22),
                                                           lineWidth: selected ? 2 : 1))
                            .shadow(color: selected ? accent.opacity(0.6) : .clear, radius: 8, y: 2)
                    )
                    .scaleEffect(selected ? 1.08 : 1)
                Text(title)
                    .font(.system(size: 13, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(selected ? accent.darker(0.15) : Snes.text)
            }
            .padding(.horizontal, 2)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var modeTabs: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODE — scroll & tap")
                .font(.system(size: 8, design: .monospaced).weight(.heavy))
                .kerning(1)
                .foregroundStyle(Snes.text.opacity(0.55))
            // Wheel-of-fortune style: snaps one button at a time, edges curve away,
            // and every notch clicks.
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(wheelEntries, id: \.self) { entry in
                        wheelButton(entry)
                            .frame(height: wheelRowHeight)
                            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                                view
                                    .scaleEffect(x: 1 - abs(phase.value) * 0.18, y: 1 - abs(phase.value) * 0.28)
                                    .opacity(1 - abs(phase.value) * 0.55)
                                    .rotation3DEffect(.degrees(phase.value * -28), axis: (x: 1, y: 0, z: 0),
                                                      perspective: 0.6)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $wheelPosition)
            .scrollIndicators(.hidden)
            .contentMargins(.vertical, 4, for: .scrollContent)
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: wheelPosition) { _, _ in wheelTick() }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Snes.bodyDark.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
        )
    }

    private let wheelRowHeight: CGFloat = 54
    @State private var wheelPosition: String?

    @ViewBuilder
    private func wheelButton(_ entry: String) -> some View {
        if entry == "REFRESH" {
            modeButton(icon: "arrow.clockwise", title: "REFRESH", accent: Snes.green, selected: true) {
                client.browserReload()
                statusText = "Refreshing the page on your Mac"
            }
        } else if let m = RemoteMode(rawValue: entry) {
            modeButton(icon: m.icon, title: m.rawValue, accent: m.accent, selected: mode == m) {
                selectMode(m)
            }
        }
    }

    private func selectMode(_ newMode: RemoteMode) {
        UISelectionFeedbackGenerator().selectionChanged()
        let applySelection = {
            withAnimation(.easeInOut(duration: 0.15)) { mode = newMode }
            statusText = newMode.welcome
            if newMode == .code {
                client.show()
                client.tab("CODE")
            }
            if newMode == .doc {
                client.show()
                client.tab("DOC")
                client.setDocumentaryReadout(documentaryReadoutEnabled)
            }
        }

        guard recorder.isListening, newMode == .code || mode == .code || newMode == .doc || mode == .doc else {
            applySelection()
            return
        }
        Task {
            _ = await recorder.stop()
            client.stopListening()
            dictateMode = false
            recordTarget = .ask
            applySelection()
        }
    }

    /// Ratchet click as the wheel passes each notch.
    private func wheelTick() {
        AudioServicesPlaySystemSound(1104) // keyboard "tock"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func modeButton(icon: String, title: String, accent: Color, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 14, design: .monospaced).weight(.black))
                    .kerning(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // Every mode wears its own colour; the active one is brighter and glows.
                Capsule()
                    .fill(LinearGradient(
                        colors: selected
                            ? [accent.lighter(0.30), accent, accent.darker(0.12)]
                            : [accent.darker(0.05).opacity(0.85), accent.darker(0.30).opacity(0.85)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        // Glass highlight across the top half.
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(selected ? 0.45 : 0.22), .clear],
                                                 startPoint: .top, endPoint: .center))
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )
                    .overlay(Capsule().strokeBorder(
                        selected ? Color.white.opacity(0.85) : Color.white.opacity(0.18),
                        lineWidth: selected ? 1.5 : 1))
                    .shadow(color: selected ? accent.opacity(0.7) : .black.opacity(0.35),
                            radius: selected ? 8 : 2, y: selected ? 0 : 2)
            )
            .scaleEffect(selected ? 1.0 : 0.96)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Talk (universal voice control — any app on the Mac)

    /// Press to speak, Peeky plans and does it on the Mac; press again to
    /// stop and send. Sits in the corner of every pad. The Mac's STATUS stream
    /// lands in the status line (and is spoken aloud, in ClickyClient).
    private var cornerTalkButton: some View {
        Button(action: talkTapped) {
            VStack(spacing: 1) {
                Image(systemName: talkRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .black))
                Text(talkRecording ? "STOP" : "TALK")
                    .font(.system(size: 11, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 74, height: 74)
            .background(
                Circle()
                    .fill(talkRecording ? Snes.red : Snes.talk)
                    .shadow(color: (talkRecording ? Snes.red : Snes.talk).opacity(0.55), radius: 10, y: 3)
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(talkRecording ? "Stop and send" : "Talk to Peeky")
        .accessibilityHint(talkRecording ? "Double tap when you're done speaking"
                                          : "Double tap, then say what you want your Mac to do")
    }

    private func confirmView(_ confirm: ClickyClient.PendingConfirm) -> some View {
        // "Send to X in Gmail?\n\n<preview>" — headline first, the passage
        // (if any) shown as a quoted card underneath it.
        let parts = confirm.question.components(separatedBy: "\n\n")
        let headline = parts.first ?? confirm.question
        let preview = parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return Group {
            if let sendTo = confirm.sendTo {
                sendConfirmCard(to: sendTo, preview: preview, spoken: confirm.question)
            } else if let runIn = confirm.runIn {
                sendConfirmCard(to: runIn, preview: preview, spoken: confirm.question, run: true)
            } else if Self.isSendShaped(headline) {
                // A send the Mac couldn't attribute to a recipient still gets
                // the send card, never the bare yes/no.
                sendConfirmCard(to: "", preview: preview, spoken: confirm.question)
            } else {
                genericConfirmCard(headline: headline, preview: preview, spoken: confirm.question)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Alpine sunset behind the card, dimmed enough to read white on.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                .overlay(
                    Image(uiImage: Self.confirmBackdrop ?? UIImage())
                        .resizable()
                        .scaledToFill()
                        .overlay(
                            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.75)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        )
    }

    /// Loose JPEG in the bundle — `UIImage(named:)` only guesses `.png`,
    /// so load it by URL.
    private static let confirmBackdrop: UIImage? = {
        guard let url = Bundle.main.url(forResource: "ConfirmBackground", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }()

    private static func isSendShaped(_ headline: String) -> Bool {
        let lowered = headline.lowercased()
        return lowered.contains("send") || lowered.contains("reply")
    }

    /// The last gate before a message leaves: who it's going to, what it
    /// says, and two pills — grey Cancel, blue Send. Cancel is the safe
    /// default and sits where a thumb lands first.
    private func sendConfirmCard(to recipient: String, preview: String, spoken: String, run: Bool = false) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Text("Confirm Action")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .dynamicTypeSize(.large ... .accessibility4)
                    .foregroundStyle(.white)
                (run ? Text("Are you sure you want to run this in \(Text(recipient).fontWeight(.heavy).foregroundColor(.white))?")
                     : recipient.isEmpty ? Text("Are you sure you want to send this message?")
                     : Text("Are you sure you want to send this message to \(Text(recipient).fontWeight(.heavy).foregroundColor(.white))?"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .dynamicTypeSize(.large ... .accessibility4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(run ? "Confirm action. Are you sure you want to run this in \(recipient)? \(preview)"
                                    : recipient.isEmpty ? "Confirm action. Are you sure you want to send this message? \(preview)"
                                    : "Confirm action. Are you sure you want to send this message to \(recipient)? \(preview)")

            if !preview.isEmpty {
                previewQuote(preview)
            }

            HStack(spacing: 14) {
                pillButton("Cancel", prominent: false) { respondConfirm(false) }
                pillButton(run ? "Run" : "Send", prominent: true) { respondConfirm(true) }
            }
            Spacer(minLength: 0)
        }
    }

    private func genericConfirmCard(headline: String, preview: String, spoken: String) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("CONFIRM")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.45))
                Text(headline)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .dynamicTypeSize(.large ... .accessibility5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Peeky wants to confirm: \(spoken)")

            if !preview.isEmpty {
                previewQuote(preview)
            }

            HStack(spacing: 14) {
                confirmButton("No", icon: "xmark", color: Snes.red, prominent: false) { respondConfirm(false) }
                confirmButton("Yes", icon: "checkmark", color: Snes.green, prominent: true) { respondConfirm(true) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func previewQuote(_ preview: String) -> some View {
        Text(preview)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                // Solid near-black so the quote stays legible over the photo.
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.14).opacity(0.94))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            )
            .accessibilityHidden(true)
    }

    private func pillButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .dynamicTypeSize(.large ... .accessibility3)
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule().fill(prominent ? Color(red: 0.0, green: 0.48, blue: 1.0)
                                             : Color.white.opacity(0.14))
                )
                .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.18 : 0.10), lineWidth: 1))
                .shadow(color: prominent ? Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.45) : .clear,
                        radius: 14, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func confirmButton(_ title: String, icon: String, color: Color, prominent: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .black))
                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .dynamicTypeSize(.large ... .accessibility5)
            }
            .foregroundStyle(prominent ? Color.white : color.lighter(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(
                        prominent
                            ? AnyShapeStyle(LinearGradient(colors: [color.lighter(0.15), color.darker(0.15)],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(color.opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(prominent ? .white.opacity(0.25) : color.opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: prominent ? color.opacity(0.55) : .clear, radius: 18, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Yes" ? "Yes, do it" : "No, cancel")
    }

    /// Pick-one card: one big button per option (e.g. each contact that
    /// matched a spoken name), plus Cancel. Same shape as the Yes/No card so
    /// it's found in the same place.
    private func choiceView(_ choice: ClickyClient.PendingChoice) -> some View {
        VStack(spacing: 12) {
            Text(choice.question)
                .font(.system(.title, design: .rounded).weight(.bold))
                .dynamicTypeSize(.large ... .accessibility5)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityLabel("Peeky asks: \(choice.question)")
            VStack(spacing: 10) {
                ForEach(Array(choice.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        client.respondChoice(index)
                        statusText = "Picked \(option)"
                    } label: {
                        Text(option)
                            .font(.system(.title, design: .rounded).weight(.black))
                            .dynamicTypeSize(.large ... .accessibility5)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 20).fill(Snes.green))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pick \(option)")
                }
                confirmButton("Cancel", icon: "xmark", color: Snes.red, prominent: false) {
                    client.respondChoice(nil)
                    statusText = "Cancelled"
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Snes.bodyDark.opacity(0.6)))
    }

    // MARK: - Gmail pad (purpose-built: every button says what it does)

    private var gmailPad: some View {
        VStack(spacing: 10) {
            padSection(title: "READ", subtitle: "Move around your inbox") {
                HStack(spacing: 8) {
                    padButton(icon: "tray.full.fill", title: "Inbox",
                                hint: "Back to the list", tint: Snes.blue) { gmailTapped("INBOX") }
                    padButton(icon: "envelope.open.fill", title: "Latest",
                                hint: "Open newest email", tint: Snes.yellow) { gmailTapped("OPEN_LATEST") }
                    padButton(icon: "trash.fill", title: "Trash",
                                hint: "Delete open email\nConfirm on Mac", tint: Snes.red) { gmailTapped("TRASH_OPEN") }
                    padButton(icon: "arrowshape.turn.up.left.fill", title: "Reply",
                                hint: "Reply to open email", tint: Snes.purple) { gmailTapped("REPLY") }
                }
            }
            padSection(title: "WRITE", subtitle: "Compose a new email — left to right") {
                HStack(spacing: 8) {
                    padButton(icon: "square.and.pencil", title: "Compose",
                                hint: "New email window", tint: Snes.green, step: 1) { gmailTapped("COMPOSE") }
                    padButton(icon: "cursorarrow.rays", title: "Subject",
                                hint: "Click into Subject", tint: Snes.green, step: 2) { gmailTapped("FOCUS_SUBJECT") }
                    padButton(icon: "text.alignleft", title: "Body",
                                hint: "Click into message", tint: Snes.green, step: 3) { gmailTapped("FOCUS_BODY") }
                    padButton(icon: "paperplane.fill", title: "Send",
                                hint: "Send the email", tint: Snes.purple, step: 4) { gmailTapped("SEND") }
                }
            }
            clickyPill
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                Text("Buttons act on the Gmail tab open in your Mac's browser.")
            }
            .font(.system(size: 9, design: .monospaced).weight(.semibold))
            .foregroundStyle(Snes.text.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Shopify pad (drives the admin tab open in Chrome on the Mac)

    /// One row of the Shopify admin's left sidebar, in the order it appears
    /// there, with the icon the remote draws for it.
    private struct ShopifySection: Identifiable {
        let name: String
        let icon: String
        var id: String { name }
    }

    private static let shopifySections: [ShopifySection] = [
        ShopifySection(name: "Home", icon: "house.fill"),
        ShopifySection(name: "Orders", icon: "bag.fill"),
        ShopifySection(name: "Products", icon: "tag.fill"),
        ShopifySection(name: "Customers", icon: "person.2.fill"),
        ShopifySection(name: "Growth", icon: "chart.line.uptrend.xyaxis"),
        ShopifySection(name: "Discounts", icon: "percent"),
        ShopifySection(name: "Content", icon: "doc.text.fill"),
        ShopifySection(name: "Markets", icon: "globe"),
        ShopifySection(name: "Finance", icon: "creditcard.fill"),
        ShopifySection(name: "Analytics", icon: "chart.bar.fill"),
        ShopifySection(name: "Online Store", icon: "storefront.fill"),
        ShopifySection(name: "Apps", icon: "square.grid.2x2.fill"),
        ShopifySection(name: "Settings", icon: "gearshape.fill"),
    ]

    /// Each parent tile and the sidebar sub-items indented under it. The
    /// parent itself is the first tab; a section with no sub-items still gets
    /// a one-tab strip. Every tab opens its own live table inside the panel.
    private static let shopifyTabSections: [String: [String]] = [
        "Home": ["Home"],
        "Orders": ["Orders", "Drafts", "Shipping labels", "Abandoned checkouts"],
        "Products": ["Products", "Collections", "Inventory", "Purchase orders",
                     "Transfers", "Gift cards"],
        "Customers": ["Customers", "Segments", "Companies"],
        "Growth": ["Growth", "Attribution", "Autopilot", "Campaigns"],
        "Discounts": ["Discounts"],
        "Content": ["Content", "Metaobjects", "Files", "Menus", "Blog posts"],
        "Markets": ["Markets", "Catalogs", "Rollouts"],
        "Finance": ["Finance", "Credit", "Payouts", "Bill Pay"],
        "Analytics": ["Analytics", "Reports", "Live View"],
        "Online Store": ["Online Store"],
        "Apps": ["Apps"],
        "Settings": ["Settings"],
    ]

    /// The cartridge's two screens: the sidebar grid, or — after tapping any
    /// tile — that section's live table read out of Chrome.
    @ViewBuilder
    private var shopifyPad: some View {
        if shopifyTableShown {
            shopifyTablesPad
        } else {
            shopifyGrid
        }
    }

    /// The admin's own look: a dark sidebar, one green-edged key per section.
    /// Every tap retargets the same admin tab already open in Chrome, so the
    /// grid is a remote for that one tab rather than a way to spawn copies.
    private var shopifyGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Snes.shopify).frame(width: 8, height: 8)
                Text("Shopify admin")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("in Chrome on your Mac")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(Self.shopifySections) { section in
                        shopifyTile(section)
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                Text("Opens in the Shopify admin tab already open in Chrome.")
            }
            .font(.system(size: 9, design: .monospaced).weight(.semibold))
            .foregroundStyle(Snes.text.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .background(shopifyPanelBackground)
    }

    /// The charcoal card both Shopify screens sit in.
    private var shopifyPanelBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.09, blue: 0.10),
                                          Color(red: 0.04, green: 0.04, blue: 0.05)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
    }

    /// One sidebar section shrunk to a phone key: Shopify-green rail, icon,
    /// name, and a chevron for "this takes you somewhere".
    private func shopifyTile(_ section: ShopifySection) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Every tile opens the live mirror; its strip is the section's
            // own sub-items (a single tab when it has none).
            shopifyParent = section.name
            shopifySection = section.name
            shopifyTableShown = true
            client.shopify(section.name)
            statusText = "Shopify — opening \(section.name) in Chrome on your Mac"
        } label: {
            HStack(spacing: 7) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 22)
                    .foregroundStyle(Snes.shopify.lighter(0.45))
                Text(section.name)
                    .font(.system(size: 13, design: .monospaced).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.13)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Snes.shopify)
                            .frame(width: 3)
                            .padding(.vertical, 10)
                            .padding(.leading, 1)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(section.name) in Shopify")
        .accessibilityHint("Opens in the Shopify admin tab in Chrome on your Mac")
    }

    // MARK: - Shopify tables (a mirror of the desktop's Orders pages)

    private var shopifyTablesPad: some View {
        VStack(spacing: 8) {
            shopifyTableTitleBar
            shopifySectionTabs
            Group {
                if let table = client.shopifyTables[shopifySection] {
                    shopifyTable(table)
                } else if let error = client.shopifyTableErrors[shopifySection] {
                    shopifyTableErrorView(error)
                } else if client.shopifyTableNone.contains(shopifySection) {
                    shopifyTableNoneView
                } else {
                    shopifyTableLoading
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(10)
        .background(shopifyPanelBackground)
    }

    private var shopifyTableTitleBar: some View {
        HStack(spacing: 8) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                shopifyTableShown = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .black))
                    Text("Shopify")
                        .font(.system(size: 12, design: .monospaced).weight(.heavy))
                }
                .foregroundStyle(Snes.shopify.lighter(0.45))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Shopify sections")

            VStack(alignment: .leading, spacing: 1) {
                Text(shopifySection)
                    .font(.system(size: 15, design: .monospaced).weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(shopifyTableSubtitle)
                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                client.shopify(shopifySection)
                statusText = "Shopify — refreshing \(shopifySection) from Chrome"
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 30)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh \(shopifySection)")
        }
        .padding(.horizontal, 2)
    }

    /// The tapped tile and its sidebar sub-items, each a tappable panel. The
    /// strip scrolls horizontally: Products alone has six tabs.
    private var shopifySectionTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Self.shopifyTabSections[shopifyParent] ?? [shopifyParent], id: \.self) { name in
                    let selected = name == shopifySection
                    Button {
                        guard !selected else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        shopifySection = name
                        client.shopify(name)
                        statusText = "Shopify — reading \(name) from Chrome"
                    } label: {
                        Text(name)
                            .font(.system(size: 11, design: .monospaced).weight(.heavy))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.65))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(selected ? Snes.shopify : Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.35 : 0.12),
                                                            lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var shopifyTableSubtitle: String {
        if let table = client.shopifyTables[shopifySection] {
            return "\(table.rows.count) \(shopifyRowNoun) · live from Chrome"
        }
        if client.shopifyTableErrors[shopifySection] != nil {
            return "couldn't read from Chrome on your Mac"
        }
        if client.shopifyTableNone.contains(shopifySection) {
            return "opened in Chrome on your Mac"
        }
        return "live from Chrome on your Mac"
    }

    private var shopifyRowNoun: String {
        switch shopifySection {
        case "Orders": "orders"
        case "Drafts": "draft orders"
        case "Shipping labels": "labels"
        case "Abandoned checkouts": "checkouts"
        default: "rows"
        }
    }

    private var shopifyTableLoading: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Reading \(shopifySection) from Chrome…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.10))
    }

    /// Home, Live View, Online Store, Autopilot and friends are dashboards,
    /// cards or charts, not grids. That is a normal answer, so this reads as
    /// plain text — no warning triangle, no "try again".
    private var shopifyTableNoneView: some View {
        VStack(spacing: 8) {
            Text("Opened in Chrome.")
                .font(.system(size: 12, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("This page isn't a table.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.10))
    }

    private func shopifyTableErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Snes.yellow)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                client.shopify(shopifySection)
            } label: {
                Text("Try again")
                    .font(.system(size: 12, design: .monospaced).weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .background(Capsule().fill(Snes.shopify))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.10))
    }

    /// The desktop's grid, shrunk to phone text: the same headers, cells and
    /// status pills, Polaris-white. Too wide for one screen, so it scrolls
    /// both ways.
    private func shopifyTable(_ table: ClickyClient.ShopifyTable) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                shopifyTableColumns(table.headers, section: table.section)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    shopifyTableRow(row, headers: table.headers, section: table.section,
                                    striped: !index.isMultiple(of: 2))
                }
            }
            .background(Color.white)
        }
        .background(Color.white)
    }

    private func shopifyTableColumns(_ headers: [String], section: String) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                Text(header)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.5))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(width: Self.shopifyColumnWidth(header, section: section), alignment: .leading)
                    .frame(height: 26, alignment: .leading)
            }
        }
        .background(Color(white: 0.95))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.14)).frame(height: 1)
        }
    }

    private func shopifyTableRow(_ row: ClickyClient.ShopifyTable.Row,
                                 headers: [String], section: String, striped: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                shopifyTableCell(index < row.cells.count ? row.cells[index] : "", header: header)
                    .padding(.horizontal, 7)
                    .frame(width: Self.shopifyColumnWidth(header, section: section), alignment: .leading)
                    .frame(height: 30, alignment: .leading)
            }
        }
        .background(striped ? Color(white: 0.975) : Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func shopifyTableCell(_ value: String, header: String) -> some View {
        switch header {
        case "Fulfillment status", "Delivery status", "Payment status", "Document status":
            if value.isEmpty {
                Color.clear.frame(height: 16)
            } else {
                shopifyStatusPill(value)
            }
        case "Order", "Draft order", "Checkout":
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.85))
                .lineLimit(1)
        default:
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func shopifyStatusPill(_ text: String) -> some View {
        let fill: Color
        switch text.lowercased() {
        case "unfulfilled", "partially fulfilled", "pending", "authorized", "partially paid":
            fill = Color(red: 1.0, green: 0.88, blue: 0.25)
        case "paid", "fulfilled", "delivered":
            fill = Color(white: 0.90)
        case "refunded", "voided", "cancelled", "canceled":
            fill = Color(white: 0.86)
        default:
            fill = Color(white: 0.93)
        }
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
    }

    /// Column widths copied from the desktop grid so the two read alike.
    /// Labels pack several fields into one cell, so theirs are wider.
    private static func shopifyColumnWidth(_ header: String, section: String) -> CGFloat {
        if section == "Shipping labels" {
            switch header {
            case "Order": return 190
            case "Items": return 180
            case "Package": return 170
            case "Weight": return 70
            case "Cost": return 70
            case "Shipping service": return 170
            case "Document status": return 95
            case "Delivery status": return 90
            default: return 90
            }
        }
        switch header {
        case "Order": return 52
        case "Flags", "": return 34
        case "Date", "Created": return 96
        case "Customer", "Customer name": return 108
        case "Destination": return 118
        case "Channel": return 84
        case "Total": return 68
        case "Items": return 50
        case "Fulfillment status": return 98
        case "Delivery status": return 86
        case "Delivery method": return 100
        case "Fulfill by": return 68
        case "Payment status": return 78
        case "Draft order": return 100
        case "PO number": return 90
        case "Status": return 90
        case "Checkout": return 160
        case "Region": return 100
        case "Recovery status": return 100
        case "Total price": return 80
        default: return 90
        }
    }

    /// Peeky toggle: bring the Mac panel up, tap again to collapse it.
    private var clickyPill: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            client.collapse()
            statusText = "Peeky toggled on your Mac — tap again to collapse / bring back"
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .bold))
                Text("PEEKY")
                    .font(.system(size: 19, design: .monospaced).weight(.black))
                Text("show / collapse on Mac")
                    .font(.system(size: 12, design: .monospaced).weight(.semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            .padding(.horizontal, 28)
            .frame(height: 54)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [Snes.blue.lighter(0.18), Snes.blue],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// Re-encodes as JPEG no larger than 1600px on its longest side so the
    /// transfer over the local network stays quick.
    private static func jpegForSending(_ image: UIImage, maxSide: CGFloat = 1600) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    private func desktopPhotoTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        desktopPick = nil
        desktopPickerShown = true
    }

    private func desktopCameraTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            statusText = "No camera available on this device"
            return
        }
        desktopCameraShown = true
    }

    private func openPeekyCode() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.show()
        client.tab("CODE")
        statusText = "Peeky Code opened on your Mac"
    }

    /// Loads the picked photo and ships it to the Mac, which writes it
    /// straight to the Desktop — no app relay needed.
    private func sendPhotoToDesktop(_ item: PhotosPickerItem) async {
        desktopPick = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            statusText = "Couldn't read that photo — try another one"
            return
        }
        await sendPhotoToDesktop(image)
    }

    /// Shared by the Photos picker and the camera. `addedToPhotos` is nil for
    /// a library pick (it's already in Photos), otherwise whether the camera
    /// shot made it into the library.
    private func sendPhotoToDesktop(_ image: UIImage, addedToPhotos: Bool? = nil) async {
        savingToDesktop = true
        statusText = "Sending photo to VIRADETH_RESUME on your Mac…"
        defer { savingToDesktop = false }
        guard let jpeg = Self.jpegForSending(image) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            statusText = "Couldn't read that photo — try another one"
            return
        }
        client.savePhoto(jpeg.base64EncodedString())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let sent = "sent (\(jpeg.count / 1024) KB) — saving to VIRADETH_RESUME…"
        switch addedToPhotos {
        case nil: statusText = "Photo \(sent)"
        case true?: statusText = "Added to Photos · \(sent)"
        case false?: statusText = "⚠︎ Couldn't add to Photos (check Settings → Peeky Remote → Photos) · \(sent)"
        }
    }

    private var spotifyCard: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    /// Bare monochrome icon button, Spotify-player style.
    private func spotifyIcon(_ name: String, size: CGFloat, dim: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(dim ? 0.6 : 0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SpotifyPressStyle())
    }

    /// Small glass tile: icon over a one-word label.
    private func spotifyTile(_ icon: String, _ title: String, accent: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(spotifyCard)
        }
        .buttonStyle(SpotifyPressStyle())
        .frame(maxWidth: .infinity)
    }

    /// A labelled group of controls, like a section printed on the console.
    private func padSection<Content: View>(title: String, subtitle: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 9, design: .monospaced).weight(.heavy))
                    .kerning(1.5)
                    .foregroundStyle(Snes.text.opacity(0.8))
                Text("— \(subtitle)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Snes.text.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            content()
                .frame(maxHeight: .infinity)
        }
        .padding(6)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Snes.bodyDark.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
        )
    }

    /// Big self-describing button: icon, name, one-line hint, and an optional
    /// step number for actions that go in order.
    private func padButton(icon: String, title: String, hint: String, tint: Color,
                           step: Int? = nil, thumbnail: UIImage? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 4) {
                    if let thumbnail {
                        // The attached photo itself, with a tick so it reads as "done".
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white, Color.green)
                                    .offset(x: 5, y: 5)
                            }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 26, weight: .bold))
                    }
                    Text(title)
                        .font(.system(size: 18, design: .monospaced).weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(hint)
                        .font(.system(size: 9, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .opacity(0.9)
                }
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let step {
                    Text("\(step)")
                        .font(.system(size: 11, design: .monospaced).weight(.black))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white))
                        .padding(6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [tint.lighter(0.18), tint],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                 startPoint: .top, endPoint: .center))
                            .padding(1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 3)
            )
        }
        .buttonStyle(.plain)
    }

    private func gmailTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.gmail(command)
        switch command {
        case "COMPOSE":
            statusText = "Gmail — opening a new email on your Mac. Next: tap Subject."
        case "FOCUS_SUBJECT":
            statusText = "Gmail — cursor is in the Subject line. Type on your Mac, then tap Body."
        case "FOCUS_BODY":
            statusText = "Gmail — cursor is in the message body. Type on your Mac, then tap Send."
        case "SEND":
            statusText = "Gmail — sending. Undo is on your Mac for a few seconds."
        case "OPEN_LATEST":
            statusText = "Gmail — opening your newest email"
        case "TRASH_OPEN":
            statusText = "Gmail — confirm Trash on your Mac (8s Undo after)"
        case "INBOX":
            statusText = "Gmail — back to your inbox"
        case "REPLY":
            statusText = "Gmail — replying. Type (or dictate) on your Mac, then tap Send."
        default:
            break
        }
    }

    // MARK: - Peeky Video pad (second screen + jog dial for the editor tab)

    private var videoPad: some View {
        let v = client.video
        return VStack(spacing: 8) {
            // Header: project on the Mac + the usual show/hide Peeky button.
            HStack(spacing: 8) {
                Circle().fill(Snes.video).frame(width: 8, height: 8)
                Text("Peeky Video")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(v.open ? v.project : "no project open")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    client.collapse()
                    statusText = "Peeky toggled on your Mac — tap again to collapse / bring back"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("PEEKY")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Snes.blue.lighter(0.25), Snes.blue],
                                                      startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: Snes.blue.opacity(0.5), radius: 6, y: 2)
                }
                .buttonStyle(SpotifyPressStyle())
            }
            .padding(.horizontal, 4)

            // Timecode readout: frames matter when nudging a cut.
            HStack(spacing: 6) {
                Text(v.open ? v.timecode : "0:00.00")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Snes.video.lighter(0.3))
                Text("/ \(v.open ? v.durationCode : "0:00.00")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if v.open && v.clipCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "film").font(.system(size: 10))
                        Text("\(v.clipIndex)/\(v.clipCount)")
                        Text(v.clipName).lineLimit(1)
                        if v.zoom > 1.01 {
                            Text(String(format: "%.1f×", v.zoom)).foregroundStyle(Snes.video.lighter(0.3))
                        }
                        if v.hasCaptions {
                            Image(systemName: "captions.bubble.fill").font(.system(size: 9))
                                .foregroundStyle(Snes.video.lighter(0.3))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                } else if v.open {
                    Text("import clips on your Mac")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 6)

            // Transport: Start · −5 · PLAY · +5 · Export
            HStack(spacing: 0) {
                spotifyIcon("backward.end.fill", size: 18) { videoTapped("START") }
                spotifyIcon("gobackward.5", size: 22) { videoTapped("SKIP -5") }
                Button { videoTapped("PLAYPAUSE") } label: {
                    Image(systemName: v.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Snes.video))
                        .shadow(color: Snes.video.opacity(0.55), radius: 12, y: 4)
                }
                .buttonStyle(SpotifyPressStyle())
                spotifyIcon("goforward.5", size: 22) { videoTapped("SKIP 5") }
                spotifyIcon(v.phase == "EXPORTING" ? "hourglass" : "square.and.arrow.up", size: 18,
                            dim: v.busy) { videoTapped("EXPORT") }
            }
            .frame(height: 66)
            .frame(maxWidth: .infinity)
            .background(spotifyCard)

            // The dial, flanked by the cut buttons and the clip buttons.
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    videoSideLabel("CUT AT PLAYHEAD")
                    spotifyTile("scissors", "Split", accent: Snes.video.lighter(0.3)) { videoTapped("SPLIT") }
                    spotifyTile("arrow.right.to.line", "Cut before") { videoTapped("CUT_BEFORE") }
                    spotifyTile("arrow.left.to.line", "Cut after") { videoTapped("CUT_AFTER") }
                    spotifyTile("arrow.left.and.right", "Rejoin") { videoTapped("REJOIN") }
                }
                .frame(maxWidth: .infinity)

                JogWheel(accent: Snes.video, mode: jogMode.icon) { detents in jogTurned(detents) }
                    .frame(width: 168, height: 168)

                VStack(spacing: 6) {
                    videoSideLabel("THIS CLIP")
                    spotifyTile("arrow.left", "Earlier") { videoTapped("EARLIER") }
                    spotifyTile("arrow.right", "Later") { videoTapped("LATER") }
                    spotifyTile("trash.fill", "Remove", accent: Color(red: 0.95, green: 0.35, blue: 0.35)) { videoTapped("REMOVE") }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            // What the dial moves, and how far per click.
            HStack(spacing: 6) {
                ForEach(JogMode.allCases, id: \.self) { m in
                    videoChip(m.rawValue, icon: m.icon, selected: jogMode == m) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        jogMode = m
                        statusText = m == .scrub
                            ? "Dial moves the playhead — clockwise forward, one frame per click"
                            : "Dial nudges the selected clip's \(m == .trimStart ? "first" : "last") frame — clockwise trims later"
                    }
                }
                Spacer(minLength: 0)
                videoChip(jogCoarse ? "×10" : "×1", icon: "dial.medium", selected: jogCoarse) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    jogCoarse.toggle()
                    statusText = jogCoarse ? "Dial: ten frames per click" : "Dial: one frame per click"
                }
            }

            // Zoom into the frame, and captions.
            HStack(spacing: 8) {
                spotifyTile("minus.magnifyingglass", "Out") { videoTapped("ZOOM_OUT") }
                spotifyTile("plus.magnifyingglass", "In") { videoTapped("ZOOM_IN") }
                spotifyTile("rectangle.arrowtriangle.2.inward", "Fill") { videoTapped("FILL") }
                spotifyTile("rectangle.arrowtriangle.2.outward", "Fit") { videoTapped("FIT") }
                spotifyTile(v.phase == "TRANSCRIBING" || v.phase == "TRANSLATING" ? "hourglass" : "captions.bubble.fill", "Subtitles",
                            accent: Snes.video.lighter(0.3)) { videoTapped("CAPTIONS") }
            }
            .frame(height: 54)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.13, blue: 0.14),
                                              Color(red: 0.07, green: 0.07, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        )
    }

    private func videoSideLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy, design: .monospaced))
            .kerning(1)
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func videoChip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Capsule().fill(selected ? Snes.video.lighter(0.2) : .white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.1), lineWidth: 1))
        }
        .buttonStyle(SpotifyPressStyle())
    }

    /// One dial click = one frame (or ten in coarse mode); clockwise is forward.
    private func jogTurned(_ detents: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        let frames = detents * (jogCoarse ? 10 : 1)
        switch jogMode {
        case .scrub: client.video("JOG \(frames)")
        case .trimStart: client.video("TRIM_START \(frames)")
        case .trimEnd: client.video("TRIM_END \(frames)")
        }
    }

    private func videoTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.video(command)
        switch command {
        case "PLAYPAUSE": statusText = "Peeky Video — play / pause"
        case "START": statusText = "Peeky Video — back to the start"
        case "SKIP -5": statusText = "Peeky Video — back five seconds"
        case "SKIP 5": statusText = "Peeky Video — forward five seconds"
        case "SPLIT": statusText = "Peeky Video — split the clip at the playhead"
        case "CUT_BEFORE": statusText = "Peeky Video — cut everything before the playhead"
        case "CUT_AFTER": statusText = "Peeky Video — cut everything after the playhead"
        case "REJOIN": statusText = "Peeky Video — glue the split nearest the playhead back together"
        case "ZOOM_IN": statusText = "Peeky Video — zoom in on this clip"
        case "ZOOM_OUT": statusText = "Peeky Video — zoom out"
        case "FILL": statusText = "Peeky Video — fill the 9:16 frame (no black bars)"
        case "FIT": statusText = "Peeky Video — show the whole picture"
        case "EARLIER": statusText = "Peeky Video — moved this clip earlier"
        case "LATER": statusText = "Peeky Video — moved this clip later"
        case "REMOVE": statusText = "Peeky Video — removed this clip from the timeline"
        case "CAPTIONS": statusText = "Peeky Video — listening to your takes and writing captions…"
        case "EXPORT": statusText = "Peeky Video — exporting 1080×1920 on your Mac…"
        default: break
        }
    }

    // MARK: - Peeky Doc pad (second screen for the film on Peeky Code Doc)

    private var docRecording: Bool { recorder.isListening && recordTarget == .doc }

    private var docPad: some View {
        let d = client.doc
        return VStack(spacing: 8) {
            // Header: what's on the Mac right now.
            HStack(spacing: 8) {
                Circle().fill(Snes.doc).frame(width: 8, height: 8)
                Text("Ask Peeky")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(d.showing ? d.momentLabel : "no documentary playing")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                if !d.codeRef.isEmpty {
                    Text(d.codeRef)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Image(systemName: documentaryReadoutEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(documentaryReadoutEnabled ? Snes.doc : .white.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Read answers aloud")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(documentaryReadoutEnabled ? "Documentary narrator" : "Off by default")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Toggle("", isOn: $documentaryReadoutEnabled)
                    .labelsHidden()
                    .tint(Snes.doc)
                    .onChange(of: documentaryReadoutEnabled) { _, enabled in
                        client.setDocumentaryReadout(enabled)
                        statusText = enabled
                            ? "Documentary narrator will read answers"
                            : "Answer read-out is off"
                    }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))

            if d.showing {
                docAskCard(d)
                docTransport(d)
                if !d.suggestions.isEmpty, d.askPhase == "IDLE" || d.askPhase == "LISTENING" {
                    docSuggestions(d)
                }
            } else {
                docLibrary
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.13, blue: 0.14),
                                              Color(red: 0.07, green: 0.07, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: d.askPhase)
    }

    /// The big Ask Peeky button, the thinking spinner, or the answer with its
    /// follow-ups — whichever the Mac says the session is in.
    @ViewBuilder private func docAskCard(_ d: ClickyClient.DocState) -> some View {
        VStack(spacing: 10) {
            switch d.askPhase {
            case "THINKING":
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Peeky is looking at \(d.timecode)…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            case "ANSWERED", "FAILED":
                ScrollView {
                    Text(client.docAnswer.isEmpty ? (d.askPhase == "FAILED" ? "Peeky couldn't answer that one." : "…") : client.docAnswer)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 190)
                .background(spotifyCard)
                HStack(spacing: 8) {
                    spotifyTile("list.number", "Show me", accent: Snes.doc) { docTapped("SHOW_ME") }
                    spotifyTile("arrow.up.right.square", "Go deeper") { docTapped("DEEPER") }
                    spotifyTile("mic.fill", "Ask another", accent: Snes.doc) { docAskTapped() }
                }
                .frame(height: 62)
                Button { docTapped("RESUME") } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Resume documentary")
                    }
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Snes.doc))
                    .shadow(color: Snes.doc.opacity(0.5), radius: 10, y: 3)
                }
                .buttonStyle(SpotifyPressStyle())
            default:
                Button { docAskTapped() } label: {
                    VStack(spacing: 6) {
                        if docRecording {
                            WaveformView(level: recorder.level, color: .white)
                                .frame(height: 30)
                        } else {
                            Image(systemName: "mic.fill").font(.system(size: 28, weight: .black))
                        }
                        Text(docRecording ? "Listening… tap to send" : "ASK PEEKY")
                            .font(.system(size: 17, weight: .black, design: .rounded))
                        Text(docRecording ? recorder.transcript.isEmpty ? "say your question" : recorder.transcript
                             : "pauses the film and listens")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .opacity(0.8)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(LinearGradient(colors: [Snes.doc.lighter(0.15), Snes.doc],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(docRecording ? 0.8 : 0.2), lineWidth: docRecording ? 2 : 1))
                            .shadow(color: Snes.doc.opacity(docRecording ? 0.8 : 0.45), radius: docRecording ? 18 : 10, y: 4)
                    )
                }
                .buttonStyle(SpotifyPressStyle())
                .modifier(KeyRecordingPulse(recording: docRecording))
            }
        }
    }

    /// Restart · −10 · PLAY/PAUSE · +10 · Stop, with a scrubber underneath.
    private func docTransport(_ d: ClickyClient.DocState) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                spotifyIcon("backward.end.fill", size: 18) { docTapped("RESTART") }
                spotifyIcon("gobackward.10", size: 22) { docTapped("SKIP -10") }
                Button { docTapped("PLAYPAUSE") } label: {
                    Image(systemName: d.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(Snes.doc))
                        .shadow(color: Snes.doc.opacity(0.55), radius: 12, y: 4)
                }
                .buttonStyle(SpotifyPressStyle())
                spotifyIcon("goforward.10", size: 22) { docTapped("SKIP 10") }
                spotifyIcon("stop.fill", size: 18, dim: true) { docTapped("STOP") }
            }
            .frame(height: 70)
            Slider(value: Binding(get: { min(d.position, max(d.duration, 0.01)) },
                                  set: { docScrub = $0 }),
                   in: 0...max(d.duration, 0.01)) { editing in
                if !editing, let t = docScrub {
                    docTapped("SEEK \(Int(t))")
                    docScrub = nil
                }
            }
            .tint(Snes.doc)
            HStack {
                Text(d.timecode)
                Spacer()
                Text(d.durationCode)
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(spotifyCard)
    }

    private func docSuggestions(_ d: ClickyClient.DocState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(d.suggestions.enumerated()), id: \.offset) { i, q in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        client.doc("SUGGEST \(i)")
                        statusText = "Asked: “\(q)”"
                    } label: {
                        Text(q)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(SpotifyPressStyle())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Nothing playing: the Mac's recent films, one tap to start any of them.
    private var docLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(client.docRecent.isEmpty ? "No documentaries yet — make one on your Mac's Peeky Code Doc tab."
                                          : "Recent documentaries — tap to play on your Mac")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(client.docRecent.prefix(12).enumerated()), id: \.offset) { i, title in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            client.doc("PLAY_RECENT \(i)")
                            statusText = "Playing “\(title)” on your Mac"
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Snes.doc)
                                Text(title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(spotifyCard)
                        }
                        .buttonStyle(SpotifyPressStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Ask Peeky: pauses the film on the Mac and records here; a second tap sends.
    private func docAskTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if blockedByActiveRecording(.doc) { return }
        if !recorder.isListening {
            recordTarget = .doc
            dictateMode = false
        }
        toggleListening()
    }

    private func docTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.doc(command)
        switch command {
        case "PLAYPAUSE": statusText = client.doc.playing ? "Paused on your Mac" : "Playing on your Mac"
        case "RESUME": statusText = "Resuming the documentary from \(client.doc.timecode)"
        case "SHOW_ME": statusText = "Peeky is drawing it out step by step…"
        case "DEEPER": statusText = "Opened in Peeky Ask on your Mac — the film stays parked here"
        case "RESTART": statusText = "From the top"
        case "STOP": statusText = "Stopped — back to the Peeky Code Doc home screen"
        default: break
        }
    }

    // MARK: - YouTube pad (controls the active YouTube tab in the browser)

    private var youtubePad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Snes.youtube).frame(width: 8, height: 8)
                Text("YouTube")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("in your browser")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    client.collapse()
                    statusText = "Peeky toggled on your Mac — tap again to collapse / bring back"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("PEEKY")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                        Text("show / hide")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        Capsule().fill(LinearGradient(colors: [Snes.blue.lighter(0.25), Snes.blue],
                                                      startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: Snes.blue.opacity(0.5), radius: 6, y: 2)
                }
                .buttonStyle(SpotifyPressStyle())
            }
            .padding(.horizontal, 4)

            // Transport: skip back 10s · PLAY/PAUSE · skip forward 10s
            HStack(spacing: 0) {
                spotifyIcon("gobackward.10", size: 22) { youtubeTapped("SKIP_BACK") }
                Spacer(minLength: 0)
                Button { youtubeTapped("PLAYPAUSE") } label: {
                    Image(systemName: "playpause.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(Circle().fill(Snes.youtube))
                        .shadow(color: Snes.youtube.opacity(0.55), radius: 12, y: 4)
                }
                .buttonStyle(SpotifyPressStyle())
                Spacer(minLength: 0)
                spotifyIcon("goforward.10", size: 22) { youtubeTapped("SKIP_FORWARD") }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(spotifyCard)

            // Mute + Fullscreen
            HStack(spacing: 8) {
                spotifyTile("speaker.slash.fill", "Mute") { youtubeTapped("MUTE") }
                spotifyTile("arrow.up.left.and.arrow.down.right", "Fullscreen") { youtubeTapped("FULLSCREEN") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Volume down / up
            HStack(spacing: 8) {
                spotifyTile("minus", "Volume") { youtubeTapped("VOLUME_DOWN") }
                spotifyTile("plus", "Volume") { youtubeTapped("VOLUME_UP") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Like / Subscribe
            HStack(spacing: 8) {
                spotifyTile("hand.thumbsup.fill", "Like", accent: Snes.youtube) { youtubeTapped("LIKE") }
                spotifyTile("bell.badge.fill", "Subscribe", accent: Snes.youtube) { youtubeTapped("SUBSCRIBE") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The browser itself, rather than what's playing in it. Open puts
            // YouTube on screen in Safari (double-tap quits it); Collapse
            // tucks the window into the Dock without pausing playback, and
            // toggles — the Mac reports back which state it landed in, so the
            // label always matches what's actually on screen.
            HStack(spacing: 8) {
                spotifyTile("safari.fill", "Open · 2× Quit", accent: Snes.youtube) { youtubeOpenTapped() }
                spotifyTile(client.youtubeCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                            client.youtubeCollapsed ? "Expand Browser" : "Collapse Browser") { youtubeTapped("COLLAPSE") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.13, blue: 0.14),
                                              Color(red: 0.07, green: 0.07, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        )
    }

    /// Open on a single tap; a double tap toggles Safari — quitting it, or
    /// opening it again when a previous double tap already closed it. The open
    /// waits out the double-tap window before it fires, otherwise a double tap
    /// would launch Safari only to quit it a moment later.
    private func youtubeOpenTapped() {
        if let pending = youtubeOpenTap {
            pending.cancel()
            youtubeOpenTap = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            client.youtube("TOGGLE_APP")
            statusText = "YouTube — quitting Safari (double-tap again to reopen it)"
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let tap = DispatchWorkItem {
            youtubeOpenTap = nil
            client.youtube("OPEN")
            statusText = "YouTube — opening in Safari · double-tap this tile to quit it"
        }
        youtubeOpenTap = tap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: tap)
    }

    private func youtubeTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.youtube(command)
        switch command {
        case "PLAYPAUSE": statusText = "YouTube — play / pause"
        case "SKIP_FORWARD": statusText = "YouTube — skip forward 10s"
        case "SKIP_BACK": statusText = "YouTube — skip back 10s"
        case "FULLSCREEN": statusText = "YouTube — fullscreen toggled"
        case "MUTE": statusText = "YouTube — mute toggled"
        case "VOLUME_UP": statusText = "YouTube — volume up"
        case "VOLUME_DOWN": statusText = "YouTube — volume down"
        case "LIKE": statusText = "YouTube — liked"
        case "SUBSCRIBE": statusText = "YouTube — subscribed"
        case "COLLAPSE": statusText = "YouTube — toggling the browser window…"
        default: break
        }
    }

    // MARK: - Class recorder pad

    /// One big button. The Mac records its own input (the wireless-mic
    /// receiver); the phone only starts and stops it, so it can sit in a
    /// pocket or lock without cutting the recording.
    private var classRecPad: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Snes.red).frame(width: 8, height: 8)
                Text("Class recorder")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("on your Mac")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(client.classRecording ? Snes.red : .white.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(client.classRecording ? "RECORDING" : "READY")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 4)

            // Which input the Mac is listening to — so you can see the mic
            // receiver is the one, not the laptop's own microphone.
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(client.classDevice.isEmpty ? "Waiting for your Mac…" : client.classDevice)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))

            Spacer(minLength: 0)

            Text(classClock(client.classRecording ? client.classElapsed : 0))
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .foregroundStyle(client.classRecording ? .white : .white.opacity(0.35))
                .minimumScaleFactor(0.6)

            classLevelMeter

            Button {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                if client.classRecording {
                    client.classRec("STOP")
                    statusText = "Saving the recording on your Mac"
                } else {
                    client.classElapsed = 0
                    client.classRec("START")
                    statusText = "Recording the class mic on your Mac"
                }
            } label: {
                ZStack {
                    Circle().fill(Snes.red)
                        .frame(width: 128, height: 128)
                        .shadow(color: Snes.red.opacity(client.classRecording ? 0.7 : 0.35), radius: 16, y: 4)
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4)
                        .frame(width: 144, height: 144)
                    if client.classRecording {
                        RoundedRectangle(cornerRadius: 8).fill(.white).frame(width: 44, height: 44)
                    } else {
                        Circle().fill(.white).frame(width: 52, height: 52)
                    }
                }
            }
            .buttonStyle(SpotifyPressStyle())
            .accessibilityLabel(client.classRecording ? "Stop and save the recording" : "Start recording")

            Text(client.classRecording ? "TAP TO STOP AND SAVE" : "TAP TO RECORD")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            Spacer(minLength: 0)

            if let error = client.classError {
                Text(error)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else if !client.classLastFile.isEmpty {
                VStack(spacing: 2) {
                    Text(client.classRecording ? "SAVING TO" : "LAST SAVED")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Desktop / Class Recordings / \(client.classLastFile)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
    }

    private func classClock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Twenty bars that light up with the mic's level, so you can tell at a
    /// glance the wireless mic is actually being heard.
    private var classLevelMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                let lit = client.classRecording && client.classLevel * 20 / 100 > i
                RoundedRectangle(cornerRadius: 2)
                    .fill(lit ? (i >= 16 ? Snes.red : Snes.green) : .white.opacity(0.12))
                    .frame(height: 16)
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeOut(duration: 0.12), value: client.classLevel)
    }

    // MARK: - Keynote pad (a TV-remote clicker)

    private var keynotePad: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Snes.keynote).frame(width: 8, height: 8)
                Text("Keynote")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("on your Mac")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(client.keynotePlaying ? Snes.green : .white.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(client.keynotePlaying ? "PLAYING" : "READY")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.08)))
            }
            .padding(.horizontal, 4)

            keynoteRing
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Black / white screen · TALK · swap displays · pointer
            HStack(spacing: 0) {
                keynoteIcon("moon.fill", "Black screen") { keynoteTapped("BLACK") }
                keynoteIcon("sun.max.fill", "White screen") { keynoteTapped("WHITE") }
                Button { talkTapped() } label: {
                    Image(systemName: talkRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(talkRecording ? Snes.red : Snes.keynote))
                        .shadow(color: (talkRecording ? Snes.red : Snes.keynote).opacity(0.5), radius: 8, y: 2)
                }
                .buttonStyle(SpotifyPressStyle())
                .frame(maxWidth: .infinity)
                .accessibilityLabel(talkRecording ? "Stop" : "Talk")
                keynoteIcon("rectangle.2.swap", "Swap displays") { keynoteTapped("SWAP") }
                keynoteIcon("cursorarrow", "Pointer") { keynoteTapped("POINTER") }
            }
            .frame(height: 56)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            // Video: one big green PLAY (first slide + show, so the movie on
            // it starts), one big red STOP, then Keynote's in-show movie keys.
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("VIDEO")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(client.keynotePlaying ? "tap ⏯ to pause / resume" : "PLAY starts from slide 1")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }
                .padding(.horizontal, 4)
                HStack(spacing: 10) {
                    keynoteWide("play.fill", client.keynotePlaying ? "PLAY / PAUSE" : "PLAY VIDEO", Snes.green) {
                        keynoteTapped("VIDEO_PLAY")
                    }
                    keynoteWide("stop.fill", "STOP", Snes.red) { keynoteTapped("VIDEO_STOP") }
                }
                HStack(spacing: 0) {
                    keynoteIcon("backward.end.fill", "Restart") { keynoteTapped("VIDEO_RESTART") }
                    keynoteIcon("backward.fill", "Rewind") { keynoteTapped("VIDEO_REWIND") }
                    keynoteIcon("playpause.fill", "Pause / resume") { keynoteTapped("VIDEO_PAUSE") }
                    keynoteIcon("forward.fill", "Fast-forward") { keynoteTapped("VIDEO_FORWARD") }
                    keynoteIcon("forward.end.fill", "Skip to end") { keynoteTapped("VIDEO_END") }
                }
                .frame(height: 50)
            }

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            HStack(spacing: 0) {
                keynoteRound("arrow.uturn.backward", "Exit") { keynoteTapped("EXIT") }
                keynoteRound("house", "Keynote") { keynoteTapped("OPEN") }
                keynoteRound(client.keynotePlaying ? "stop.fill" : "play.fill",
                             client.keynotePlaying ? "Stop show" : "Play slides") { keynoteTapped("PLAY") }
            }
            HStack(spacing: 0) {
                keynoteRound("backward.end.fill", "First") { keynoteTapped("FIRST") }
                keynoteRound("forward.end.fill", "Last") { keynoteTapped("LAST") }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.09, blue: 0.10),
                                              Color(red: 0.04, green: 0.04, blue: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        )
    }

    /// The big ring: four wedges step back / forward through the deck
    /// (up and left go back, down and right go forward, as in Keynote
    /// itself), and the centre plays, or advances once a show is running.
    private var keynoteRing: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let gapColor = Color(red: 0.04, green: 0.04, blue: 0.05)
            let inner: CGFloat = 0.22
            ZStack {
                ForEach(KeynoteDirection.allCases, id: \.self) { dir in
                    Button { keynoteTapped(dir.command) } label: {
                        ZStack {
                            KeynoteWedge(startDegrees: dir.startDegrees, innerRatio: inner)
                                .fill(Color(white: 0.17))
                            Image(systemName: dir.icon)
                                .font(.system(size: side * 0.09, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: dir.unit.x * side * 0.36, y: dir.unit.y * side * 0.36)
                        }
                        .frame(width: side, height: side)
                        .contentShape(KeynoteWedge(startDegrees: dir.startDegrees, innerRatio: inner))
                    }
                    .buttonStyle(KeynoteWedgeStyle())
                    .accessibilityLabel(dir.command == "NEXT" ? "Next slide" : "Previous slide")
                }
                // The dark seams between the wedges.
                Path { p in
                    let c = CGPoint(x: side / 2, y: side / 2)
                    let r = side / 2
                    for angle in [45.0, 135.0] {
                        let dx = cos(angle * .pi / 180) * r, dy = sin(angle * .pi / 180) * r
                        p.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                        p.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
                    }
                }
                .stroke(gapColor, lineWidth: side * 0.018)
                .frame(width: side, height: side)
                .allowsHitTesting(false)
                Button { keynoteTapped("SELECT") } label: {
                    Circle()
                        .fill(Color(white: 0.26))
                        .overlay(Circle().strokeBorder(gapColor, lineWidth: side * 0.018))
                        .overlay(
                            Text(client.keynotePlaying ? "NEXT" : "PLAY")
                                .font(.system(size: side * 0.055, weight: .black, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        )
                        .frame(width: side * inner * 2, height: side * inner * 2)
                }
                .buttonStyle(SpotifyPressStyle())
                .accessibilityLabel(client.keynotePlaying ? "Next" : "Play slideshow")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func keynoteIcon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SpotifyPressStyle())
        .accessibilityLabel(label)
    }

    /// Big pill for the two video controls that matter on stage: PLAY and STOP.
    private func keynoteWide(_ icon: String, _ title: String, _ tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                Text(title)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Capsule().fill(tint))
            .shadow(color: tint.opacity(0.45), radius: 8, y: 3)
        }
        .buttonStyle(SpotifyPressStyle())
        .accessibilityLabel(title)
    }

    private func keynoteRound(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(Color(white: 0.2)))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpotifyPressStyle())
        .accessibilityLabel(title)
    }

    private func keynoteTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.keynote(command)
        let playing = client.keynotePlaying
        switch command {
        case "OPEN": statusText = "Keynote — bringing it up on your Mac"
        case "PLAY": statusText = playing ? "Keynote — stopping the slideshow" : "Keynote — playing from the current slide"
        case "SELECT": statusText = playing ? "Keynote — next" : "Keynote — playing from the current slide"
        case "NEXT": statusText = "Keynote — next"
        case "PREV": statusText = "Keynote — previous"
        case "FIRST": statusText = "Keynote — first slide"
        case "LAST": statusText = "Keynote — last slide"
        case "EXIT": statusText = "Keynote — leaving the slideshow"
        case "BLACK": statusText = "Keynote — black screen (tap again to resume)"
        case "WHITE": statusText = "Keynote — white screen (tap again to resume)"
        case "POINTER": statusText = "Keynote — pointer shown / hidden"
        case "SWAP": statusText = "Keynote — presenter and audience displays swapped"
        case "MOVIE": statusText = playing ? "Keynote — play / pause the video on this slide"
                                           : "Keynote — starting the show; tap Video again to pause / play the movie"
        case "VIDEO_PLAY": statusText = playing ? "Keynote — video paused / resumed"
                                                : "Keynote — playing from slide 1, video starts with the slide"
        case "VIDEO_STOP": statusText = "Keynote — stopping"
        case "VIDEO_PAUSE": statusText = "Keynote — video paused / resumed"
        case "VIDEO_RESTART": statusText = "Keynote — video back to the start"
        case "VIDEO_REWIND": statusText = "Keynote — video rewinding"
        case "VIDEO_FORWARD": statusText = "Keynote — video fast-forwarding"
        case "VIDEO_END": statusText = "Keynote — video skipped to the end"
        default: break
        }
    }

    // MARK: - Header (slim status strip)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(connectionLabel)
                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Snes.text.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                snesDots
                Text("PEEKY")
                    .font(.system(size: 10, design: .monospaced).weight(.black).italic())
                    .kerning(1)
                    .foregroundStyle(Snes.purple)
            }
            if recorder.isListening {
                WaveformView(level: recorder.level)
                    .frame(height: 18)
                Text(recorder.transcript.isEmpty ? "Listening… tap STOP when done" : recorder.transcript)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Snes.red)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(permissionDenied
                     ? "Enable Microphone & Speech Recognition in Settings."
                     : statusText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Snes.text.opacity(0.65))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Snes.bodyLight)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        )
    }

    /// The four SNES logo colours.
    private var snesDots: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Circle().fill(Snes.red).frame(width: 5, height: 5)
                Circle().fill(Snes.yellow).frame(width: 5, height: 5)
            }
            HStack(spacing: 2) {
                Circle().fill(Snes.green).frame(width: 5, height: 5)
                Circle().fill(Snes.blue).frame(width: 5, height: 5)
            }
        }
        .padding(.trailing, 4)
    }

    private var connectionColor: Color {
        switch client.status {
        case .connected: Snes.green
        case .searching: Snes.yellow
        case .failed: Snes.red
        }
    }

    private var connectionLabel: String {
        switch client.status {
        case .connected: "Mac linked"
        case .searching: "Finding Mac…"
        case .failed(let message): "Error: \(message)"
        }
    }

    // MARK: - Keypad

    private var keypad: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let gap: CGFloat = isLandscape ? 8 : 12
            let topInset: CGFloat = isLandscape ? 8 : 12
            // Portrait keeps square hero keys. Landscape uses the full
            // two-column width and lets height fit the available rows.
            let columnW = (geo.size.width - gap) / 2
            // ASK / CAPTURE / COLLAPSE sit three across, so that row is
            // sized to thirds; the two-across rows below keep halves.
            let trioW = (geo.size.width - gap * 2) / 3
            let minimumPhotoH: CGFloat = isLandscape ? 40 : 56
            let rowH = (geo.size.height - topInset - gap * 8) / 9.8
            let chromeBudget = max(88, geo.size.height - topInset - gap * 6
                                   - minimumPhotoH * 3 - min(120, columnW) * 2)
            let calculatedSwitchH = min(max(64, rowH * 1.55), max(64, chromeBudget - max(64, rowH)))
            let switchH = isLandscape ? min(82, max(52, geo.size.height * 0.15)) : calculatedSwitchH
            let calculatedBannerH = min(max(64, rowH), max(36, chromeBudget - switchH))
            let bannerH = isLandscape ? 44 : calculatedBannerH
            let available = geo.size.height - topInset - gap * 6 - switchH - bannerH
            let squareHeroSide = max(0, min(trioW, (available - minimumPhotoH * 3) / 2))
            let landscapeKeyH = max(minimumPhotoH, available / 5)
            let heroW = isLandscape ? columnW : squareHeroSide
            let trioHeroW = isLandscape ? trioW : squareHeroSide
            let heroH = isLandscape ? landscapeKeyH : squareHeroSide
            let photoH = isLandscape ? landscapeKeyH : max(minimumPhotoH, (available - heroH * 2) / 3)
            VStack(spacing: gap) {
                ScreenSwitch(count: client.screenCount, current: client.currentScreen) { n in
                    client.screen(n)
                    statusText = n == 2 ? "Peeky → Screen 2 (your monitor)" : "Peeky → Screen 1 (MacBook)"
                }
                .frame(width: geo.size.width, height: switchH)
                HStack(spacing: gap) {
                    key("on", label: "ON", icon: "power", tint: Snes.blue, lit: true,
                        h: bannerH, w: columnW, banner: true)
                    // ENTIRE SCREEN: a full-resolution PNG of the whole display
                    // Chrome's front window is on, left on the Mac clipboard.
                    key("entire_screen", label: "ENTIRE SCREEN", icon: "display",
                        tint: Snes.purple, lit: true,
                        h: bannerH, w: columnW, banner: true)
                }
                HStack(alignment: .top, spacing: gap) {
                    // ASK records on the phone and sends `ASK <text>`: the Mac
                    // answers exactly as it does for ⌥⌘C (screenshot of the
                    // display under the pointer, or the focused editor file).
                    key("5", label: askRecording ? "STOP" : "ASK",
                        icon: askRecording ? "stop.fill" : "questionmark.bubble.fill",
                        tint: askRecording ? Snes.red : Snes.green, lit: true,
                        h: heroH, w: trioHeroW, hero: !isLandscape, waveform: askRecording)
                        // Temporarily off at the user's request; delete these
                        // two lines to bring ASK back.
                        .disabled(true)
                        .opacity(0.35)
                    key("2", label: "CAPTURE", icon: "camera.viewfinder", tint: Snes.blue, lit: true,
                        h: heroH, w: trioHeroW, hero: !isLandscape)
                    // COLLAPSE is the panel header's "Minimize to corner"
                    // button: Peeky tucks into its corner dot. Once it is
                    // there the key reads EXPAND and brings it back.
                    key("minimize", label: client.peekyLayout == "COLLAPSED" ? "EXPAND" : "COLLAPSE",
                        icon: client.peekyLayout == "COLLAPSED" ? "arrow.up.left.and.arrow.down.right"
                                                                : "arrow.down.right.and.arrow.up.left",
                        tint: Snes.green, lit: true,
                        h: heroH, w: trioHeroW, hero: !isLandscape)
                }
                HStack(alignment: .top, spacing: gap) {
                    key("keynote", label: "KEYNOTE", icon: "play.rectangle.on.rectangle.fill",
                        tint: Snes.keynote, lit: true,
                        h: heroH, w: heroW, hero: !isLandscape) { _ in selectMode(.keynote) }
                        .accessibilityLabel("Open the Keynote clicker")
                    key("talk", label: talkRecording ? "STOP" : "TALK",
                        icon: talkRecording ? "stop.fill" : "mic.fill",
                        tint: talkRecording ? Snes.red : Snes.talk, lit: true,
                        h: heroH, w: heroW, hero: !isLandscape, waveform: talkRecording) { _ in talkTapped() }
                        // Temporarily off at the user's request; delete these
                        // two lines to bring TALK back.
                        .disabled(true)
                        .opacity(0.35)
                }
                HStack(alignment: .top, spacing: gap) {
                    key("terminal", label: "TERMINAL", icon: "terminal",
                        tint: Snes.red, lit: true, h: photoH, w: heroW)
                        .accessibilityLabel("Open Terminal on Mac")
                    key("photos", label: savingToDesktop ? "SAVING…" : "PHOTOS",
                        icon: savingToDesktop ? "arrow.up.circle.dotted" : "photo.on.rectangle.angled",
                        tint: Snes.blue, lit: true,
                        h: photoH, w: heroW) { _ in desktopPhotoTapped() }
                        .disabled(savingToDesktop)
                }
                HStack(alignment: .top, spacing: gap) {
                    key("paste", label: "PASTE", icon: "doc.on.clipboard",
                        tint: Snes.talk, lit: true, h: photoH, w: heroW)
                        .accessibilityLabel("Paste on Mac")
                    key("camera", label: "CAMERA", icon: "camera.fill", tint: Snes.purple, lit: true,
                        h: photoH, w: heroW) { _ in desktopCameraTapped() }
                        .disabled(savingToDesktop)
                }
                HStack(alignment: .top, spacing: gap) {
                    key("enter", label: "ENTER", icon: "return",
                        tint: Snes.talk, lit: true, h: photoH, w: heroW)
                        .accessibilityLabel("Press Enter on Mac")
                    // Parked here and turned off at the user's request;
                    // delete the `.disabled`/`.opacity` pair to bring
                    // Peeky Code back.
                    key("code", label: "PEEKY CODE", icon: "chevron.left.forwardslash.chevron.right",
                        tint: Snes.red, lit: true, h: photoH, w: heroW) { _ in openPeekyCode() }
                        .accessibilityLabel("Open Peeky Code on Mac")
                        .disabled(true)
                        .opacity(0.35)
                }
            }
            .padding(.top, topInset)
        }
        .photosPicker(isPresented: $desktopPickerShown, selection: $desktopPick,
                      matching: .images, photoLibrary: .shared())
        .fullScreenCover(isPresented: $desktopCameraShown) {
            CameraCapture { image in
                desktopCameraShown = false
                guard let image else { return }
                Task {
                    // Keep the full-size shot in Photos, then send the Mac a
                    // phone-friendly copy for VIRADETH_RESUME.
                    let inPhotos = await CameraRoll.add(image)
                    await sendPhotoToDesktop(image, addedToPhotos: inPhotos)
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: desktopPick) { _, item in
            guard let item else { return }
            Task { await sendPhotoToDesktop(item) }
        }
    }

    private func row(_ keys: [some View], h: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { $0.element.frame(height: h) }
        }
    }

    /// Saturated tiles match the banner; active tiles gain a brighter face and rim.
    private func key(_ id: String, label: String? = nil, icon: String? = nil, tint: Color? = nil, lit: Bool = false,
                     h: CGFloat? = nil, w: CGFloat? = nil, small: Bool = false, hero: Bool = false,
                     banner: Bool = false, waveform: Bool = false,
                     action: ((String) -> Void)? = nil) -> some View {
        let face = tint ?? Snes.key
        let active = waveform || (id == "photos" && savingToDesktop)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            (action ?? tapped)(id)
        } label: {
            ZStack {
                if waveform {
                    WaveformView(level: recorder.level, bars: 16,
                                 color: .white.opacity(0.55), maxHeight: min(34, max(4, (h ?? 134) - 100)))
                        // The fixed-width bars must not expand a compact square.
                        .frame(width: 93)
                        .scaleEffect(x: min(1, max(0, (w ?? 121) - 28) / 93), y: 1)
                        .frame(width: max(0, (w ?? 121) - 28))
                        .allowsHitTesting(false)
                }
                if banner {
                    HStack(spacing: 10) {
                        Image(systemName: icon ?? "")
                            .font(.system(size: 22, weight: .bold))
                        Text(label ?? id)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .allowsTightening(true)
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 10)
                } else if !hero, let label {
                    HStack(spacing: 10) {
                        Image(systemName: icon ?? "")
                            .font(.system(size: 20, weight: .semibold))
                        Text(label)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: label)
                } else {
                    ZStack(alignment: .topLeading) {
                        Image(systemName: icon ?? "")
                            .font(.system(size: hero ? 30 : 22, weight: .semibold))
                        Text(label ?? id)
                            .font(.system(size: hero ? 15 : 13, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .padding(14)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: label)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if banner {
                    shape.fill(LinearGradient(colors: [face.lighter(0.18), face],
                                              startPoint: .top, endPoint: .bottom))
                } else if active {
                    shape.fill(id == "3" || id == "photos" ? face.lighter(0.1) : Snes.red)
                } else {
                    shape.fill(LinearGradient(colors: [face.lighter(0.12), face.darker(0.06)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(active ? 0.6 : 0.22),
                                        lineWidth: active ? 2 : 1))
        }
        .buttonStyle(PadKeyStyle())
        .frame(width: w, height: h)
        .modifier(KeyRecordingPulse(recording: waveform))
    }

    // MARK: - Actions

    private var askRecording: Bool { recorder.isListening && recordTarget == .ask }
    private var dictateRecording: Bool { recorder.isListening && recordTarget == .dictate }
    private var talkRecording: Bool { recorder.isListening && recordTarget == .talk }

    /// A record key was tapped while a *different* mode is still recording.
    /// Refuse (only the key that started a recording can stop it) and tell the
    /// user which key to stop first, so the tap isn't silently swallowed.
    private func blockedByActiveRecording(_ wanted: RecordTarget) -> Bool {
        guard recorder.isListening, recordTarget != wanted else { return false }
        // TALK is open-ended (say a command, pause, keep going), so tapping
        // ASK or DICTATE mid-TALK is how a session naturally ends: finish the
        // TALK — whatever was said since the last pause still runs — and
        // start the new recording, instead of demanding a separate stop tap.
        if recordTarget == .talk, wanted == .ask || wanted == .dictate {
            Task {
                let text = await recorder.stop()
                if text.isEmpty { client.stopListening() } else { client.talk(text) }
                recordTarget = wanted
                dictateMode = wanted == .dictate
                client.show()
                client.tab(wanted == .dictate ? "DICTATE" : "ASK")
                toggleListening()
            }
            return true
        }
        let running: String
        switch recordTarget {
        case .talk: running = "TALK"
        case .dictate: running = "DICTATE"
        case .ask: running = "ASK"
        case .doc: running = "Ask Peeky (Doc)"
        }
        showRecordingNotice("\(running) is still recording — stop it first")
        return true
    }

    /// Error haptic plus a warning shown where the user is actually looking
    /// while recording, fading out after a couple of seconds.
    private func showRecordingNotice(_ message: String) {
        showNotice(message, ok: false, seconds: 1.6)
    }

    /// Black pill toast: a green check for good news, a warning for the rest.
    private func showNotice(_ message: String, ok: Bool, seconds: Double) {
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        recordingNoticeTask?.cancel()
        noticeOK = ok
        recordingNotice = message
        recordingNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            recordingNotice = nil
        }
    }

    /// Black pill toast, centered at the bottom of the console.
    private func toast(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: noticeOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(noticeOK ? Snes.green.lighter(0.25) : Snes.yellow)
            Text(message)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .padding(.horizontal, 24)
    }

    private func talkTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if blockedByActiveRecording(.talk) { return }
        if !recorder.isListening {
            recordTarget = .talk
            dictateMode = false
        }
        toggleListening()
    }

    private func respondConfirm(_ confirmed: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(confirmed ? .success : .warning)
        client.respondConfirm(confirmed)
    }

    private func tapped(_ label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch label {
        case "on":
            client.show()
            statusText = "Peeky is ON and visible on your Mac"
        case "entire_screen":
            client.entireScreen()
            statusText = "Copying your Chrome screen to the Mac clipboard…"
        case "minimize":
            if client.peekyLayout == "COLLAPSED" {
                client.expand()
                statusText = "Peeky brought back from the corner on your Mac"
            } else {
                client.minimize()
                statusText = "Peeky minimized to the corner on your Mac — tap EXPAND to bring it back"
            }
        case "4":
            client.show()
            client.tab("ASK")
            dictateMode = false
            statusText = "Ask — tap the mic (ASK) to speak your question"
        case "5":
            // Ask record. Refuses while another mode is recording.
            if blockedByActiveRecording(.ask) { return }
            if !recorder.isListening {
                dictateMode = false
                recordTarget = .ask
            }
            toggleListening()
        case "1":
            client.show()
            client.tab("DICTATE")
            dictateMode = true
            statusText = "Capture + Dictate — tap CAPTURE to grab a region, DICTATE to talk"
        case "2":
            // Just capture — the Mac switches to Capture + Dictate when the grab lands.
            client.capture()
            statusText = "Capture — drag a region on your Mac, or tap CAPTURE again to cancel"
        case "3":
            // Dictate record. Refuses while another mode is recording.
            if blockedByActiveRecording(.dictate) { return }
            if !recorder.isListening {
                dictateMode = true
                recordTarget = .dictate
                client.show()
                client.tab("DICTATE")
            }
            toggleListening()
        case "terminal":
            client.show()
            client.tab("TERMINAL")
            statusText = "Peeky Terminal opened on your Mac"
        case "enter":
            client.enter()
            statusText = "Enter pressed on your Mac"
        case "paste":
            client.show()
            client.tab("TERMINAL")
            client.paste()
            statusText = "Pasted into Peeky Terminal on your Mac"
        default:
            break
        }
    }

    private func toggleListening() {
        if recorder.isListening {
            Task {
                let text = await recorder.stop()
                switch recordTarget {
                case _ where text.isEmpty:
                    // The Mac is still in its listening state for ask/dictate/talk
                    // — tell it to stand down.
                    if recordTarget == .doc { client.doc("STOP_ASK") } else { client.stopListening() }
                    switch recordTarget {
                    case .talk: statusText = "Didn't catch that — press TALK and try again"
                    case .doc: statusText = "Didn't catch that — tap Ask Peeky and try again"
                    default: statusText = "Didn't catch that — tap \(dictateMode ? "DICTATE" : "ASK") and try again"
                    }
                case .doc:
                    client.doc("ASK_TEXT \(text)")
                    statusText = "Asked about \(client.doc.momentLabel): “\(text)”"
                case .dictate:
                    client.dictate(text)
                    statusText = "On your Mac's clipboard (with the latest capture): “\(text)”"
                case .ask:
                    client.ask(text)
                    statusText = "Sent: “\(text)”"
                case .talk:
                    client.talk(text)
                    statusText = "Sent to Peeky: “\(text)”"
                }
            }
        } else {
            guard !permissionDenied else { return }
            do {
                try recorder.start()
                recorder.onPartial = { [client] text in client.partial(text) }
                switch recordTarget {
                case .talk: client.listenTalk()
                case .doc: client.doc("ASK")
                default: client.listen()
                }
                switch recordTarget {
                case .dictate: statusText = "Listening… speak, then tap STOP to copy to your Mac"
                case .ask: statusText = "Listening… speak, then tap STOP to ask"
                case .doc: statusText = "Paused at \(client.doc.momentLabel) — ask your question, then tap Stop"
                case .talk: statusText = "Listening… say a command, pause and Peeky does it, keep going, then tap Stop"
                }
            } catch {
                statusText = "Mic error: \(error.localizedDescription)"
            }
        }
    }

    private var consoleBackground: some View {
        // SNES console grey, slightly darker at the bottom like moulded plastic.
        LinearGradient(colors: [Snes.body, Snes.bodyDark],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Super Nintendo palette.
/// A rack-mount toggle for which display Peeky is on: a brushed-steel plate,
/// "SCREEN 2" (the monitor) engraved above and "SCREEN 1" (the MacBook) below,
/// and a red lever that snaps up or down with a heavy click. The lever draws
/// itself from what the Mac reports, so dragging Peeky by hand on the Mac
/// moves the lever too. With one display the lever is pinned down and greyed.
struct ScreenSwitch: View {
    let count: Int
    /// 1-based display Peeky is on; 0 when the panel is hidden.
    let current: Int
    let onFlip: (Int) -> Void

    /// Where the lever is drawn: -1 up (Screen 2), +1 down (Screen 1). While
    /// the Mac hasn't said yet, or Peeky is hidden, it rests where it was.
    @State private var lever: CGFloat = 1
    @State private var pressed = false

    private var enabled: Bool { count >= 2 }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let plateInset: CGFloat = 4
            let bezel: CGFloat = min(h * 0.62, 96)
            let travel = h * 0.22
            ZStack {
                plate
                // Engraved rule across the middle: the plate reads as two
                // equal halves, SCREEN 2 above, SCREEN 1 below, and the
                // lever's pivot sits exactly on it.
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1.5)
                    Rectangle().fill(Color.white.opacity(0.45)).frame(height: 1)
                }
                .padding(.horizontal, plateInset + 14)
                HStack(spacing: 0) {
                    Spacer()
                    engraving
                    Spacer()
                    ZStack {
                        bezelView(size: bezel)
                        leverView(length: h * 0.34, travel: travel)
                    }
                    .frame(width: bezel + 24)
                    Spacer()
                    lamps
                    Spacer()
                }
                .padding(.horizontal, plateInset + 10)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        pressed = true
                        // Follow the finger a little, so it feels like a real lever.
                        let pull = max(-1, min(1, value.translation.height / (travel * 1.2)))
                        lever = resting + pull * 0.6
                    }
                    .onEnded { value in
                        pressed = false
                        guard enabled else { snap(to: 1); return }
                        let target: Int
                        if abs(value.translation.height) > 10 {
                            target = value.translation.height < 0 ? 2 : 1
                        } else {
                            // A tap flips to the other position.
                            target = (current == 2) ? 1 : 2
                        }
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        snap(to: target == 2 ? -1 : 1)
                        onFlip(target)
                    }
            )
            .onAppear { snap(to: resting, animated: false) }
            .onChange(of: current) { _, _ in snap(to: resting) }
            .onChange(of: count) { _, _ in snap(to: resting) }
            .opacity(enabled ? 1 : 0.55)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screen switch")
            .accessibilityValue(current == 2 ? "Screen 2, monitor" : "Screen 1, MacBook")
            .accessibilityHint(enabled ? "Flips Peeky to the other display" : "Only one display is attached")
        }
    }

    /// Where the lever belongs given what the Mac says.
    private var resting: CGFloat {
        guard enabled else { return 1 }
        if current >= 2 { return -1 }
        if current == 1 { return 1 }
        return lever < 0 ? -1 : 1
    }

    private func snap(to value: CGFloat, animated: Bool = true) {
        if animated {
            withAnimation(.interpolatingSpring(mass: 0.6, stiffness: 420, damping: 18)) { lever = value }
        } else {
            lever = value
        }
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(colors: [Color(white: 0.70), Color(white: 0.56), Color(white: 0.66), Color(white: 0.52)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                // Brushed grain.
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    var i = 0
                    while y < size.height {
                        let alpha = (i % 3 == 0) ? 0.10 : 0.05
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(.white.opacity(alpha)), lineWidth: 0.5)
                        y += 2
                        i += 1
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .black.opacity(0.45)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            )
            .overlay(alignment: .topLeading) { screw.padding(7) }
            .overlay(alignment: .topTrailing) { screw.padding(7) }
            .overlay(alignment: .bottomLeading) { screw.padding(7) }
            .overlay(alignment: .bottomTrailing) { screw.padding(7) }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.35)], center: .topLeading, startRadius: 0, endRadius: 7))
            .frame(width: 8, height: 8)
            .overlay(Image(systemName: "plus").font(.system(size: 5, weight: .black)).foregroundStyle(.black.opacity(0.6)))
    }

    private var engraving: some View {
        VStack(spacing: 0) {
            engravedLabel("SCREEN 2", sub: "MONITOR", on: current == 2)
                .frame(maxHeight: .infinity)
            engravedLabel("SCREEN 1", sub: "MACBOOK", on: current == 1)
                .frame(maxHeight: .infinity)
        }
    }

    private func engravedLabel(_ text: String, sub: String, on: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(text)
                .font(.system(size: 17, weight: .black, design: .monospaced))
                .kerning(1.0)
            Text(sub)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .kerning(1.6)
                .opacity(0.75)
        }
        .foregroundStyle(on && enabled ? Color.white : Color(white: 0.16))
        .shadow(color: on && enabled ? .white.opacity(0.6) : .white.opacity(0.35), radius: on ? 3 : 0, y: on ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: on)
    }

    /// Two indicator lamps on the right: green ACTIVE on the chosen screen.
    private var lamps: some View {
        VStack(spacing: 0) {
            lamp(on: current == 2).frame(maxHeight: .infinity)
            lamp(on: current == 1).frame(maxHeight: .infinity)
        }
    }

    private func lamp(on: Bool) -> some View {
        let lit = on && enabled
        return Circle()
            .fill(RadialGradient(colors: lit ? [Color(red: 0.55, green: 1, blue: 0.55), Color(red: 0.05, green: 0.65, blue: 0.2)]
                                             : [Color(white: 0.30), Color(white: 0.12)],
                                 center: .topLeading, startRadius: 0, endRadius: 8))
            .frame(width: 15, height: 15)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
            .shadow(color: lit ? Color.green.opacity(0.9) : .clear, radius: 7)
            .animation(.easeInOut(duration: 0.2), value: lit)
    }

    private func bezelView(size: CGFloat) -> some View {
        ZStack {
            // Hex nut.
            HexNut()
                .fill(LinearGradient(colors: [Color(white: 0.80), Color(white: 0.40)], startPoint: .top, endPoint: .bottom))
                .overlay(HexNut().stroke(Color.black.opacity(0.5), lineWidth: 1))
                .frame(width: size, height: size)
            // Threaded collar.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.75), Color(white: 0.25)], center: .center, startRadius: size * 0.1, endRadius: size * 0.36))
                .frame(width: size * 0.62, height: size * 0.62)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
            // Socket hole.
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: size * 0.30, height: size * 0.30)
        }
    }

    private func leverView(length: CGFloat, travel: CGFloat) -> some View {
        // A lever pivoting at the socket, drawn pointing straight up and
        // rotated: lever -1 → 0° (up, Screen 2), +1 → 180° (down, Screen 1),
        // with a few degrees of overshoot so it reads as leaning on its stop.
        let angle = Angle(degrees: 90 + Double(lever) * 96)
        let red = Color(red: 0.80, green: 0.16, blue: 0.12)
        return ZStack(alignment: .top) {
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.45)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 13, height: length * 0.50)
                .offset(y: -length * 0.50)
            Capsule()
                .fill(LinearGradient(colors: [red.lighter(0.30), red, red.darker(0.25)], startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .frame(width: 30, height: length * 0.66)
                .offset(y: -length * 1.02)
                .shadow(color: .black.opacity(0.55), radius: 4, x: 3, y: 4)
        }
        .frame(width: 34, height: 1)
        .rotationEffect(angle, anchor: .bottom)
        .offset(y: pressed ? 1 : 0)
        .scaleEffect(pressed ? 0.98 : 1, anchor: .bottom)
    }
}

/// Six-sided nut, flat sides top and bottom.
private struct HexNut: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 + .pi / 6
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

enum Snes {
    static let body = Color(red: 0.72, green: 0.72, blue: 0.75)      // light grey plastic
    static let bodyLight = Color(red: 0.86, green: 0.86, blue: 0.88)
    static let bodyDark = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let key = Color(red: 0.36, green: 0.36, blue: 0.40)       // dark grey console buttons
    static let slot = Color(red: 0.42, green: 0.42, blue: 0.46)
    static let text = Color(red: 0.16, green: 0.16, blue: 0.20)
    static let purple = Color(red: 0.36, green: 0.30, blue: 0.62)
    static let red = Color(red: 0.86, green: 0.22, blue: 0.16)
    static let yellow = Color(red: 0.96, green: 0.78, blue: 0.10)
    static let green = Color(red: 0.16, green: 0.62, blue: 0.36)
    static let blue = Color(red: 0.16, green: 0.30, blue: 0.72)
    /// Peeky Video's editing-suite teal.
    static let video = Color(red: 0.12, green: 0.62, blue: 0.70)
    /// Shopify's admin green, for the store pad.
    static let shopify = Color(red: 0.0, green: 0.50, blue: 0.38)
    static let youtube = Color(red: 0.94, green: 0.13, blue: 0.13)
    /// Peeky Code Doc's streaming-service red.
    static let doc = Color(red: 0.90, green: 0.04, blue: 0.08)
    static let talk = Color(red: 0.98, green: 0.55, blue: 0.05)
    /// Keynote's app-icon blue.
    static let keynote = Color(red: 0.10, green: 0.50, blue: 0.95)
}

/// Owns only presentation state, so stopping a recording also cancels its pulse.
private struct KeyRecordingPulse: ViewModifier {
    let recording: Bool
    @State private var expanded = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(expanded ? 1.02 : 1)
            .onChange(of: recording, initial: true) { _, active in
                withAnimation(active
                              ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                              : .easeOut(duration: 0.15)) {
                    expanded = active
                }
            }
    }
}

/// Pad keys sink slightly under the finger, like a real controller button.
private struct PadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension Color {
    /// Blends toward black by `amount` (0–1).
    func darker(_ amount: Double) -> Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = 1 - amount
        return Color(red: r * k, green: g * k, blue: b * k, opacity: a)
    }

    /// Blends toward white by `amount` (0–1).
    func lighter(_ amount: Double) -> Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: r + (1 - r) * amount, green: g + (1 - g) * amount,
                     blue: b + (1 - b) * amount, opacity: a)
    }
}

/// A jog dial in the spirit of the QW38: drag a finger around the rim and the
/// ring turns with it, clicking once per detent. Clockwise detents are
/// positive (forward / later), counter-clockwise negative.
struct JogWheel: View {
    var accent: Color
    /// SF Symbol shown in the hub — what the dial is currently moving.
    var mode: String
    var onDetents: (Int) -> Void

    @State private var rotation = 0.0
    @State private var lastTouchAngle: Double?
    @State private var residual = 0.0
    private let detentDegrees = 9.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.24, green: 0.24, blue: 0.26),
                                                  Color(red: 0.10, green: 0.10, blue: 0.11)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
                    .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                // Tick ring — rotates with the finger so the dial feels like it turns.
                Canvas { context, canvasSize in
                    let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let r = size / 2
                    for i in 0..<60 {
                        let a = (Double(i) * 6 + rotation) * .pi / 180
                        let major = i % 5 == 0
                        let inner = r - (major ? 20 : 13)
                        let outer = r - 7
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                        tick.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                        context.stroke(tick, with: .color(.white.opacity(major ? 0.75 : 0.32)),
                                       style: StrokeStyle(lineWidth: major ? 2.2 : 1.2, lineCap: .round))
                    }
                }
                // Hub
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.20, blue: 0.22),
                                                  Color(red: 0.12, green: 0.12, blue: 0.13)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .frame(width: size * 0.46, height: size * 0.46)
                Image(systemName: mode)
                    .font(.system(size: size * 0.14, weight: .bold))
                    .foregroundStyle(accent)
                // Fixed index mark at 12 o'clock.
                VStack {
                    Triangle()
                        .fill(accent)
                        .frame(width: 10, height: 7)
                        .rotationEffect(.degrees(180))
                        .shadow(color: accent.opacity(0.8), radius: 3)
                    Spacer()
                }
                .frame(height: size)
                .padding(.top, 2)
            }
            .frame(width: size, height: size)
            .position(centre)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let a = atan2(value.location.y - centre.y, value.location.x - centre.x) * 180 / .pi
                        if let last = lastTouchAngle {
                            var delta = a - last
                            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                            rotation += delta
                            residual += delta
                            let steps = Int(residual / detentDegrees)
                            if steps != 0 {
                                residual -= Double(steps) * detentDegrees
                                onDetents(steps)
                            }
                        }
                        lastTouchAngle = a
                    }
                    .onEnded { _ in
                        lastTouchAngle = nil
                        residual = 0
                    }
            )
        }
    }
}

/// Points up; rotate for other directions.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Subtle scale + dim on press, like Spotify's own controls.
struct SpotifyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One quarter of the Keynote ring: an annular sector 90° wide, starting
/// at `startDegrees` (0° is three o'clock, increasing clockwise on screen).
struct KeynoteWedge: Shape {
    var startDegrees: Double
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio * 2
        let start = Angle.degrees(startDegrees)
        let end = Angle.degrees(startDegrees + 90)
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

enum KeynoteDirection: CaseIterable {
    case up, right, down, left

    var command: String {
        switch self {
        case .up, .left: "PREV"
        case .down, .right: "NEXT"
        }
    }

    var icon: String {
        switch self {
        case .up: "chevron.up"
        case .right: "chevron.right"
        case .down: "chevron.down"
        case .left: "chevron.left"
        }
    }

    var startDegrees: Double {
        switch self {
        case .right: -45
        case .down: 45
        case .left: 135
        case .up: 225
        }
    }

    var unit: CGPoint {
        switch self {
        case .up: CGPoint(x: 0, y: -1)
        case .right: CGPoint(x: 1, y: 0)
        case .down: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        }
    }
}

/// Wedges can't scale like a tile without overlapping their neighbours,
/// so a press just lifts the fill.
struct KeynoteWedgeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Simple animated mic-level waveform that glows red while listening.
struct WaveformView: View {
    var level: CGFloat
    var bars: Int = 28
    var color: Color = Snes.red
    var maxHeight: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = sin(t * 8 + Double(i) * 0.7) * 0.5 + 0.5
                    let height = 4 + (level * maxHeight + 4) * CGFloat(wobble)
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    NumpadView()
}

/// Adds a camera shot to the user's Photos library. The in-app camera
/// (UIImagePickerController) hands the picture back without keeping it, so
/// without this the only copy would be the one on the Mac.
private enum CameraRoll {
    /// Returns true once the photo is in the library, false if permission was
    /// refused or the write failed.
    @discardableResult
    static func add(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }
}

/// The system camera, returning the shot (or nil if cancelled).
private struct CameraCapture: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
