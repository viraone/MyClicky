import SwiftUI
import AudioToolbox
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
    enum RecordTarget { case ask, dictate, whatsapp, talk }
    @State private var recordTarget: RecordTarget = .ask
    /// Which WhatsApp chat the current dictation is for.
    @State private var whatsappChat: WhatsAppChat = .test
    /// Photo picker state: which chat the picked photo goes to, and the pick itself.
    @State private var photoChat: WhatsAppChat?
    @State private var photoPickerShown = false
    @State private var photoPick: PhotosPickerItem?
    @State private var cameraShown = false
    @State private var sendingPhoto = false
    /// Chat with a photo preview waiting on the Mac; Send must not re-open it.
    @State private var photoAttachedIn: WhatsAppChat?
    /// Small copy of the attached photo, shown on the Photo button as proof it went.
    @State private var attachedThumb: UIImage?
    /// Typed-message alert state: which chat "Text" was tapped for, and the draft.
    @State private var showingTextCompose = false
    @State private var textComposeChat: WhatsAppChat = .test
    @State private var textDraft = ""
    /// Quick-save state: send a photo straight to the Mac's Desktop, no chat involved.
    @State private var desktopPickerShown = false
    @State private var desktopPick: PhotosPickerItem?
    @State private var desktopCameraShown = false
    @State private var savingToDesktop = false

    struct WhatsAppChat: Equatable {
        let label: String
        let icon: String
        let name: String
        static let test = WhatsAppChat(label: "Test", icon: "person.3.fill", name: "Test")
        static let vip = WhatsAppChat(label: "VIP", icon: "star.fill",
                                      name: "viradeth xay-ananh- VIP Automated Resume System")
    }
    /// Which "cartridge" is loaded: the desktop remote or Gmail mode.
    @State private var mode: RemoteMode = .remote
    /// Playlist the Spotify "Add to playlist" button targets; editable by tapping the label.
    @AppStorage("spotifyPlaylist") private var spotifyPlaylist = "Playlist 2027"
    @State private var editingPlaylist = false
    @State private var playlistDraft = ""
    /// The pending single-tap Open, held back until the double-tap window
    /// closes; a second tap cancels it and sends Quit instead.
    @State private var youtubeOpenTap: DispatchWorkItem?

    enum RemoteMode: String, CaseIterable {
        /// The keypad. Talk isn't a mode: its button rides in the corner of
        /// every pad (see `cornerTalkButton`), so it needs no cartridge.
        case remote = "Mobile Peeky"
        case gmail = "GMAIL"
        case spotify = "SPOTIFY"
        case whatsapp = "WHATSAPP"
        case youtube = "YOUTUBE"

        var icon: String {
            switch self {
            case .remote: ""
            case .gmail: "envelope.fill"
            case .spotify: "music.note"
            case .whatsapp: "bubble.left.and.bubble.right.fill"
            case .youtube: "play.rectangle.fill"
            }
        }

        /// One-word label for the portrait strip, where there's no room for
        /// "Mobile Peeky".
        var shortName: String {
            switch self {
            case .remote: "PEEKY"
            default: rawValue
            }
        }

        var accent: Color {
            switch self {
            case .remote: Snes.purple
            case .gmail: Snes.red
            case .spotify: Snes.spotify
            case .whatsapp: Snes.whatsapp
            case .youtube: Snes.youtube
            }
        }

        var welcome: String {
            switch self {
            case .remote: "Tap PEEKY to open it on your Mac (tap again to hide)"
            case .gmail: "Gmail mode — buttons control Gmail on your Mac"
            case .spotify: "Spotify mode — buttons control the Spotify app on your Mac"
            case .whatsapp: "WhatsApp mode — buttons control the WhatsApp app on your Mac"
            case .youtube: "YouTube mode — buttons control the YouTube tab open in your browser"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // The app is locked to portrait, but the layout still keys off
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
            client.onWhatsAppStatus = { message, ok in
                guard mode == .whatsapp else { return }
                statusText = (ok ? "✓ " : "⚠︎ ") + message
                if !ok { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            }
            client.onSavePhotoStatus = { message, ok in
                statusText = (ok ? "✓ " : "⚠︎ ") + message
                showNotice(ok ? "Added to VIRADETH_RESUME on your Desktop" : message,
                           ok: ok, seconds: ok ? 2.4 : 3.5)
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

    /// Entries in the scrolling mode wheel: the Refresh action plus every mode.
    /// REFRESH and Mobile Peeky swap places so Mobile Peeky sits at the top,
    /// within easy thumb reach, since it's the mode used most.
    private var wheelEntries: [String] {
        var entries = ["REFRESH"] + RemoteMode.allCases.map(\.rawValue)
        if let refreshIndex = entries.firstIndex(of: "REFRESH"),
           let remoteIndex = entries.firstIndex(of: RemoteMode.remote.rawValue) {
            entries.swapAt(refreshIndex, remoteIndex)
        }
        return entries
    }

    /// The active mode's pad, with the corner Talk button and any pending
    /// confirm/choice card layered on. Shared by both orientations.
    private var pad: some View {
        Group {
            switch mode {
            case .remote: keypad
            case .gmail: gmailPad
            case .spotify: spotifyPad
            case .whatsapp: whatsappPad
            case .youtube: youtubePad
            }
        }
        // Talk rides along in the corner of every pad but the keypad,
        // which has a full-size TALK key of its own.
        // `safeAreaInset` rather than an overlay: it reserves its own
        // space instead of sitting on top of a key or tile and
        // swallowing taps meant for what's underneath.
        .safeAreaInset(edge: .trailing, alignment: .bottom, spacing: 6) {
            // The trailing padding is what holds it off the right
            // edge — raise it to move Talk further left, lower it to
            // push it back toward the corner.
            if mode != .remote { cornerTalkButton.padding(.trailing, 44) }
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
        HStack(spacing: 0) {
            ForEach(wheelEntries, id: \.self) { entry in
                stripButton(entry)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
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
                withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                UISelectionFeedbackGenerator().selectionChanged()
                statusText = m.welcome
            }
            .overlay(alignment: .topTrailing) {
                if m == .whatsapp, client.whatsappUnread > 0 {
                    unreadBadge(client.whatsappUnread).offset(x: 6, y: -6)
                } else if m == .gmail, client.gmailUnread > 0 {
                    unreadBadge(client.gmailUnread).offset(x: 6, y: -6)
                }
            }
        }
    }

    private func stripItem(icon: String, title: String, accent: Color, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 40, height: 40)
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
                    .font(.system(size: 10, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                statusText = m.welcome
            }
            .overlay(alignment: .topTrailing) {
                if m == .whatsapp, client.whatsappUnread > 0 {
                    unreadBadge(client.whatsappUnread)
                        .offset(x: 4, y: -6)
                        .transition(.scale.combined(with: .opacity))
                } else if m == .gmail, client.gmailUnread > 0 {
                    unreadBadge(client.gmailUnread)
                        .offset(x: 4, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: client.whatsappUnread)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: client.gmailUnread)
        }
    }

    /// Small red pill with the unread count — silent, works while the phone is on DND.
    private func unreadBadge(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 6 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.3), Color(red: 0.85, green: 0.1, blue: 0.1)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            )
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

    // MARK: - WhatsApp pad (controls the WhatsApp desktop app on the Mac)

    // Each section is wrapped in AnyView on purpose: the combined modifier
    // chain (photosPicker + fullScreenCover + onChange + alert + six-button
    // rows) produced a generic type so deeply nested that the Swift runtime
    // overflowed its stack just decoding the type name when this pad first
    // appeared. Erasing per section keeps every type shallow.
    private var whatsappPad: some View {
        VStack(spacing: 10) {
            whatsappChatsSection
            Spacer()
            clickyPill
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                Text("Buttons act on the WhatsApp app on your Mac.")
            }
            .font(.system(size: 9, design: .monospaced).weight(.semibold))
            .foregroundStyle(Snes.text.opacity(0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    private var whatsappChatsSection: AnyView {
        AnyView(
            padSection(title: "CHATS", subtitle: "Open → Reply (speak, tap again to stop) → check it → Send · Photo attaches from your library") {
                VStack(spacing: 8) {
                    AnyView(whatsappRow(.test))
                    AnyView(whatsappRow(.vip))
                }
            }
            .photosPicker(isPresented: $photoPickerShown, selection: $photoPick,
                          matching: .images, photoLibrary: .shared())
            .fullScreenCover(isPresented: $cameraShown) {
                CameraCapture { image in
                    cameraShown = false
                    guard let image, let chat = photoChat else { photoChat = nil; return }
                    Task { await sendPhoto(image, to: chat) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoPick) { _, item in
                guard let item, let chat = photoChat else { return }
                Task { await sendPhoto(item, to: chat) }
            }
            .alert("Type a message", isPresented: $showingTextCompose) {
                TextField("Message", text: $textDraft)
                Button("Type it") { whatsappSendTypedText() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Peeky types this into \(textComposeChat.label) on your Mac — you still tap Send.")
            }
        )
    }

    /// Peeky toggle: bring the Mac panel up (e.g. to see what was typed), tap again to collapse it.
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

    /// One chat: open it, dictate a reply into it, send what's typed there.
    private func whatsappRow(_ chat: WhatsAppChat) -> some View {
        let recording = whatsappRecording && whatsappChat == chat
        return HStack(spacing: 8) {
            padButton(icon: chat.icon, title: chat.label,
                      hint: "Open on your Mac", tint: Snes.whatsapp) { whatsappOpenChat(chat) }
            padButton(icon: "keyboard", title: "Text",
                      hint: "Type — Peeky types it there", tint: Snes.whatsapp) { whatsappTextTapped(chat) }
            padButton(icon: recording ? "stop.fill" : "mic.fill",
                      title: recording ? "Stop" : "Reply",
                      hint: recording ? "Tap when you're done talking" : "Dictate — Peeky types it there",
                      tint: recording ? Snes.red : Snes.whatsapp) { whatsappReplyTapped(chat) }
            let attached = photoAttachedIn == chat
            let sending = sendingPhoto && photoChat == chat
            padButton(icon: "paperplane.fill", title: attached ? "Send photo" : "Send",
                      hint: attached ? "Photo is waiting in \(chat.label) on your Mac" : "Send what's typed in \(chat.label)",
                      tint: attached ? Snes.blue : Snes.whatsapp) { whatsappSendTapped(chat) }
            padButton(icon: sending ? "arrow.up.circle.dotted" : "photo.on.rectangle.angled",
                      title: sending ? "Sending…" : attached ? "Attached" : "Photo",
                      hint: sending ? "Copying to your Mac…"
                          : attached ? "Tap to pick a different photo" : "Pick from Photos — attaches in \(chat.label)",
                      tint: attached ? Snes.yellow : Snes.whatsapp,
                      thumbnail: attached ? attachedThumb : nil) { whatsappPhotoTapped(chat) }
                .disabled(sendingPhoto)
                .animation(.easeInOut(duration: 0.2), value: attached)
            padButton(icon: "camera.fill", title: "Camera",
                      hint: "Snap a photo — attaches in \(chat.label)", tint: Snes.whatsapp) { whatsappCameraTapped(chat) }
                .disabled(sendingPhoto)
        }
    }

    private func whatsappPhotoTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        photoPick = nil
        photoChat = chat
        photoPickerShown = true
    }

    private func whatsappCameraTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            statusText = "No camera available on this device"
            return
        }
        photoChat = chat
        cameraShown = true
    }

    /// Loads the picked photo, shrinks it to a phone-friendly JPEG and ships it
    /// to the Mac, which pastes it into the chat's compose box (not yet sent —
    /// tap Send to send it, or type a caption first).
    private func sendPhoto(_ item: PhotosPickerItem, to chat: WhatsAppChat) async {
        photoPick = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            photoChat = nil
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            statusText = "Couldn't read that photo — try another one"
            return
        }
        await sendPhoto(image, to: chat)
    }

    /// Shared by the Photos picker and the camera.
    private func sendPhoto(_ image: UIImage, to chat: WhatsAppChat) async {
        sendingPhoto = true
        statusText = "WhatsApp — preparing photo for \(chat.label)…"
        defer {
            sendingPhoto = false
            photoChat = nil
        }
        guard let jpeg = Self.jpegForSending(image) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            statusText = "Couldn't read that photo — try another one"
            return
        }
        client.whatsapp("PHOTO_IN \(chat.name)\t\(jpeg.base64EncodedString())")
        attachedThumb = Self.jpegForSending(image, maxSide: 160).flatMap(UIImage.init(data:))
        photoAttachedIn = chat
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        statusText = "Photo sent to your Mac (\(jpeg.count / 1024) KB) — WhatsApp is attaching it in \(chat.label)…"
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

    /// Loads the picked photo and ships it to the Mac, which writes it
    /// straight to the Desktop — no WhatsApp relay needed.
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

    /// Shared by the Photos picker and the camera.
    private func sendPhotoToDesktop(_ image: UIImage) async {
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
        statusText = "Photo sent (\(jpeg.count / 1024) KB) — saving to VIRADETH_RESUME…"
    }

    private func whatsappTextTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        textComposeChat = chat
        textDraft = ""
        showingTextCompose = true
    }

    private func whatsappSendTypedText() {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        photoAttachedIn = nil
        client.whatsapp("TYPE_TEXT_IN \(textComposeChat.name)\t\(trimmed)")
        statusText = "WhatsApp — typing into \(textComposeChat.label) on your Mac"
    }

    private func whatsappReplyTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if blockedByActiveRecording(.whatsapp) { return }
        if recorder.isListening {
            // Only the row that started the recording can stop it.
            guard whatsappChat == chat else {
                showRecordingNotice("Still recording for \(whatsappChat.label) — tap its Stop first")
                return
            }
        } else {
            recordTarget = .whatsapp
            dictateMode = false
            whatsappChat = chat
            photoAttachedIn = nil
            client.whatsapp("OPEN_CHAT \(chat.name)")
        }
        toggleListening()
    }

    private func whatsappSendTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if photoAttachedIn == chat {
            // Clicking the chat row again would dismiss the attachment preview.
            client.whatsapp("SEND")
            photoAttachedIn = nil
        } else {
            client.whatsapp("SEND_IN \(chat.name)")
        }
        statusText = "WhatsApp — sent in \(chat.label)"
    }

    private func whatsappOpenChat(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        photoAttachedIn = nil
        client.whatsapp("OPEN_CHAT \(chat.name)")
        statusText = "WhatsApp — opening \(chat.label) on your Mac"
    }

    // MARK: - Spotify pad (controls the Spotify app on the Mac)

    private var spotifyPad: some View {
        VStack(spacing: 8) {
            // Header: wordmark + editable target-playlist chip.
            HStack(spacing: 8) {
                Circle().fill(Snes.spotify).frame(width: 8, height: 8)
                Text("Spotify")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("on your Mac")
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
                Button {
                    playlistDraft = spotifyPlaylist
                    editingPlaylist = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note.list").font(.system(size: 10, weight: .semibold))
                        Text(spotifyPlaylist).lineLimit(1)
                        Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Snes.spotify.lighter(0.25))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Snes.spotify.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Snes.spotify.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            // Transport: shuffle · previous · PLAY · next · repeat
            HStack(spacing: 0) {
                spotifyIcon("shuffle", size: 18, dim: true) { spotifyTapped("SHUFFLE") }
                Spacer(minLength: 0)
                spotifyIcon("backward.end.fill", size: 26) { spotifyTapped("PREVIOUS") }
                Spacer(minLength: 0)
                Button { spotifyTapped("PLAYPAUSE") } label: {
                    Image(systemName: "playpause.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 66, height: 66)
                        .background(Circle().fill(Snes.spotify))
                        .shadow(color: Snes.spotify.opacity(0.55), radius: 12, y: 4)
                }
                .buttonStyle(SpotifyPressStyle())
                Spacer(minLength: 0)
                spotifyIcon("forward.end.fill", size: 26) { spotifyTapped("NEXT") }
                Spacer(minLength: 0)
                spotifyIcon("repeat", size: 18, dim: true) { spotifyTapped("REPEAT") }
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(spotifyCard)

            // Volume pill + Like + What's on
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    spotifyIcon("speaker.wave.1.fill", size: 16) { spotifyTapped("VOLUME_DOWN") }
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 22)
                    spotifyIcon("speaker.slash.fill", size: 16, dim: true) { spotifyTapped("MUTE") }
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 22)
                    spotifyIcon("speaker.wave.3.fill", size: 16) { spotifyTapped("VOLUME_UP") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(spotifyCard)

                spotifyTile("heart.fill", "Like", accent: Color(red: 0.95, green: 0.35, blue: 0.45)) { spotifyTapped("LIKE") }
                spotifyTile("waveform", "What's on") { spotifyTapped("NOW_PLAYING") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Playlist actions
            HStack(spacing: 8) {
                Button { spotifyTapped("ADD_CURRENT \(spotifyPlaylist)") } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 20, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add to playlist")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text("What's playing → \(spotifyPlaylist)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .opacity(0.7).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [Snes.spotify.lighter(0.12), Snes.spotify],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                }
                .buttonStyle(SpotifyPressStyle())
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

                spotifyTile("plus.rectangle.on.folder.fill", "New playlist") { spotifyTapped("NEW_PLAYLIST") }
                    .frame(width: 120)
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
        .alert("Target playlist", isPresented: $editingPlaylist) {
            TextField("Playlist name", text: $playlistDraft)
            Button("Save") {
                let trimmed = playlistDraft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { spotifyPlaylist = trimmed }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the playlist name exactly as it appears in Spotify.")
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

    private func spotifyTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.spotify(command)
        switch command {
        case "PLAYPAUSE": statusText = "Spotify — play / pause"
        case "NEXT": statusText = "Spotify — next track"
        case "PREVIOUS": statusText = "Spotify — previous track"
        case "VOLUME_UP": statusText = "Spotify — louder"
        case "VOLUME_DOWN": statusText = "Spotify — quieter"
        case "MUTE": statusText = "Spotify — mute / unmute"
        case "SHUFFLE": statusText = "Spotify — shuffle toggled"
        case "REPEAT": statusText = "Spotify — repeat toggled"
        case "NOW_PLAYING": statusText = "Spotify — showing what's playing on your Mac"
        case "NEW_PLAYLIST": statusText = "Spotify — creating a new playlist on your Mac"
        case "LIKE": statusText = "Spotify — toggling Liked Songs"
        case _ where command.hasPrefix("ADD_CURRENT "): statusText = "Spotify — adding this song to “\(spotifyPlaylist)”"
        default: break
        }
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
                Text(recorder.transcript.isEmpty
                     ? (recordTarget == .whatsapp ? "Listening… tap Stop when done" : "Listening… tap STOP when done")
                     : recorder.transcript)
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
            let gap: CGFloat = 12
            let topInset: CGFloat = 12
            // Reserve enough square width for the unchanged hero labels and
            // horizontal photo captions, shrinking the chrome on compact heights.
            let rowH = (geo.size.height - topInset - gap * 6) / 7.8
            let columnW = (geo.size.width - gap) / 2
            let minimumPhotoH: CGFloat = 56
            let chromeBudget = max(100, geo.size.height - topInset - gap * 4
                                   - minimumPhotoH - min(120, columnW) * 2)
            let switchH = min(max(64, rowH * 1.55), max(64, chromeBudget - max(64, rowH)))
            let bannerH = min(max(64, rowH), max(36, chromeBudget - switchH))
            let available = geo.size.height - topInset - gap * 4 - switchH - bannerH
            let heroW = max(0, min(columnW, (available - minimumPhotoH) / 2))
            let heroH = heroW
            let photoH = max(minimumPhotoH, available - heroH * 2)
            VStack(spacing: gap) {
                ScreenSwitch(count: client.screenCount, current: client.currentScreen) { n in
                    client.screen(n)
                    statusText = n == 2 ? "Peeky → Screen 2 (your monitor)" : "Peeky → Screen 1 (MacBook)"
                }
                .frame(width: geo.size.width, height: switchH)
                HStack(spacing: gap) {
                    key("0", label: "PEEKY", icon: "sparkles", tint: Snes.purple, lit: true,
                        h: bannerH, w: columnW, banner: true)
                    key("strip", label: "COLLAPSE", icon: "chevron.left", tint: Snes.green, lit: true,
                        h: bannerH, w: columnW, banner: true)
                }
                HStack(alignment: .top, spacing: gap) {
                    // ASK records on the phone and sends `ASK <text>`: the Mac
                    // answers exactly as it does for ⌥⌘C (screenshot of the
                    // display under the pointer, or the focused editor file).
                    key("5", label: askRecording ? "STOP" : "ASK",
                        icon: askRecording ? "stop.fill" : "questionmark.bubble.fill",
                        tint: askRecording ? Snes.red : Snes.green, lit: true,
                        h: heroH, w: heroW, hero: true, waveform: askRecording)
                    key("3", label: dictateRecording ? "STOP" : "DICTATE",
                        icon: dictateRecording ? "stop.fill" : "waveform",
                        tint: Snes.red, lit: true,
                        h: heroH, w: heroW, hero: true, waveform: dictateRecording)
                }
                HStack(alignment: .top, spacing: gap) {
                    key("2", label: "CAPTURE", icon: "camera.viewfinder", tint: Snes.blue, lit: true,
                        h: heroH, w: heroW, hero: true)
                    key("talk", label: talkRecording ? "STOP" : "TALK",
                        icon: talkRecording ? "stop.fill" : "mic.fill",
                        tint: talkRecording ? Snes.red : Snes.talk, lit: true,
                        h: heroH, w: heroW, hero: true, waveform: talkRecording) { _ in talkTapped() }
                }
                HStack(alignment: .top, spacing: gap) {
                    key("photos", label: savingToDesktop ? "SAVING…" : "PHOTOS",
                        icon: savingToDesktop ? "arrow.up.circle.dotted" : "photo.on.rectangle.angled",
                        tint: Snes.blue, lit: true,
                        h: photoH, w: heroW) { _ in desktopPhotoTapped() }
                        .disabled(savingToDesktop)
                    key("camera", label: "CAMERA", icon: "camera.fill", tint: Snes.purple, lit: true,
                        h: photoH, w: heroW) { _ in desktopCameraTapped() }
                        .disabled(savingToDesktop)
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
                Task { await sendPhotoToDesktop(image) }
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
                    }
                    .padding(.horizontal, 14)
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
    private var whatsappRecording: Bool { recorder.isListening && recordTarget == .whatsapp }
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
        case .whatsapp: running = "the WhatsApp reply"
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
        case "0":
            // Toggle: the Mac shows Peeky if hidden/collapsed, collapses it if open.
            client.collapse()
            statusText = "Peeky toggled — tap PEEKY again to hide or bring it back"
        case "strip":
            client.toggleStrip()
            statusText = "Peeky's compact bar toggled on your Mac"
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
                client.show()
                client.tab("ASK")
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
        case "enter":
            client.collapse()
            statusText = "Peeky collapsed on your Mac"
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
                    // (WhatsApp records locally only) — tell it to stand down.
                    if recordTarget != .whatsapp { client.stopListening() }
                    switch recordTarget {
                    case .whatsapp: statusText = "Didn't catch that — tap Reply and try again"
                    case .talk: statusText = "Didn't catch that — press TALK and try again"
                    default: statusText = "Didn't catch that — tap \(dictateMode ? "DICTATE" : "ASK") and try again"
                    }
                case .whatsapp:
                    client.whatsapp("TYPE_TEXT_IN \(whatsappChat.name)\t\(text.replacingOccurrences(of: "\n", with: " "))")
                    statusText = "Typed in \(whatsappChat.label) on your Mac — tap Send if it looks right: “\(text)”"
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
                case .whatsapp: break
                case .talk: client.listenTalk()
                default: client.listen()
                }
                switch recordTarget {
                case .whatsapp: statusText = "Listening… speak your reply, then tap Stop"
                case .dictate: statusText = "Listening… speak, then tap STOP to copy to your Mac"
                case .ask: statusText = "Listening… speak, then tap STOP to ask"
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
    static let spotify = Color(red: 0.11, green: 0.66, blue: 0.33)
    static let whatsapp = Color(red: 0.07, green: 0.55, blue: 0.40)
    static let youtube = Color(red: 0.94, green: 0.13, blue: 0.13)
    static let talk = Color(red: 0.98, green: 0.55, blue: 0.05)
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

/// Subtle scale + dim on press, like Spotify's own controls.
struct SpotifyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
