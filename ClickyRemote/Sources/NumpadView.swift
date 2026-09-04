import SwiftUI
import AudioToolbox
import PhotosUI

/// A 22-key numeric keypad skinned like a Super Nintendo console.
/// Key "0" toggles Clicky on the Mac (show / collapse); "4" records a question;
/// "1" opens Capture + Dictate, "2" starts a region capture, "3" records dictation.
struct NumpadView: View {
    @StateObject private var client = ClickyClient()
    @StateObject private var recorder = SpeechRecorder()
    @State private var statusText = "Tap CLICKY to open it on your Mac (tap again to hide)"
    @State private var permissionDenied = false
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

    enum RemoteMode: String, CaseIterable {
        case talk = "TALK"
        case remote = "REMOTE"
        case gmail = "GMAIL"
        case spotify = "SPOTIFY"
        case whatsapp = "WHATSAPP"
        case youtube = "YOUTUBE"

        var icon: String {
            switch self {
            case .talk: "mic.fill"
            case .remote: "desktopcomputer"
            case .gmail: "envelope.fill"
            case .spotify: "music.note"
            case .whatsapp: "bubble.left.and.bubble.right.fill"
            case .youtube: "play.rectangle.fill"
            }
        }

        var accent: Color {
            switch self {
            case .talk: Snes.talk
            case .remote: Snes.purple
            case .gmail: Snes.red
            case .spotify: Snes.spotify
            case .whatsapp: Snes.whatsapp
            case .youtube: Snes.youtube
            }
        }

        var welcome: String {
            switch self {
            case .talk: "Talk mode — press the button and say what you need"
            case .remote: "Tap CLICKY to open it on your Mac (tap again to hide)"
            case .gmail: "Gmail mode — buttons control Gmail on your Mac"
            case .spotify: "Spotify mode — buttons control the Spotify app on your Mac"
            case .whatsapp: "WhatsApp mode — buttons control the WhatsApp app on your Mac"
            case .youtube: "YouTube mode — buttons control the YouTube tab open in your browser"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    header
                    modeTabs
                        .frame(maxHeight: .infinity)
                    Text("SUPER CLICKY\nENTERTAINMENT SYSTEM")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced).italic())
                        .kerning(1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Snes.text.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                Group {
                    switch mode {
                    case .talk: talkPad
                    case .remote: keypad
                    case .gmail: gmailPad
                    case .spotify: spotifyPad
                    case .whatsapp: whatsappPad
                    case .youtube: youtubePad
                    }
                }
                .frame(width: geo.size.width * 0.78)
            }
        }
        .padding(10)
        .background(consoleBackground.ignoresSafeArea())
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
            client.start()
            permissionDenied = !(await SpeechRecorder.requestPermissions())
        }
    }

    // MARK: - Mode tabs (cartridge selector)

    /// Entries in the scrolling mode wheel: the Refresh action plus every mode.
    private var wheelEntries: [String] { ["REFRESH"] + RemoteMode.allCases.map(\.rawValue) }

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
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: client.whatsappUnread)
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
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
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

    // MARK: - Talk pad (universal voice control — any app on the Mac)

    /// One giant button: press to speak, Clicky plans and does it on the Mac.
    /// Shows the Mac's STATUS stream in large text (spoken aloud too, in
    /// ClickyClient) and turns into two huge Yes/No buttons when an
    /// irreversible step needs confirming.
    private var talkPad: some View {
        VStack(spacing: 12) {
            talkMessageView
            Group {
                if let confirm = client.pendingConfirm {
                    confirmView(confirm)
                } else {
                    talkButton
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if client.pendingConfirm == nil {
                whatsItSayButton
            }
        }
        .padding(10)
    }

    private var talkMessageView: some View {
        ScrollView {
            Text(client.talkMessage.isEmpty
                 ? "Press the button and say what you need — Clicky will do it on your Mac."
                 : client.talkMessage)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .dynamicTypeSize(.large ... .accessibility5)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(client.talkMessage.isEmpty
                                     ? "Ready. Press the button and say what you need."
                                     : client.talkMessage)
        }
        .frame(maxHeight: 120)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Snes.bodyDark.opacity(0.6)))
    }

    private var talkButton: some View {
        Button(action: talkTapped) {
            VStack(spacing: 12) {
                Image(systemName: talkRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 64, weight: .black))
                Text(talkRecording ? "STOP" : "TALK")
                    .font(.system(.largeTitle, design: .rounded).weight(.black))
                    .dynamicTypeSize(.large ... .accessibility5)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Circle()
                    .fill(talkRecording ? Snes.red : Snes.talk)
                    .shadow(color: (talkRecording ? Snes.red : Snes.talk).opacity(0.6), radius: 18, y: 6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(talkRecording ? "Stop and send" : "Talk to Clicky")
        .accessibilityHint(talkRecording ? "Double tap when you're done speaking"
                                          : "Double tap, then say what you want your Mac to do")
    }

    private func confirmView(_ confirm: (id: String, question: String)) -> some View {
        VStack(spacing: 16) {
            Text(confirm.question)
                .font(.system(.title, design: .rounded).weight(.bold))
                .dynamicTypeSize(.large ... .accessibility5)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .accessibilityLabel("Clicky wants to confirm: \(confirm.question)")
            HStack(spacing: 12) {
                confirmButton("Yes", color: Snes.green) { respondConfirm(true) }
                confirmButton("No", color: Snes.red) { respondConfirm(false) }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Snes.bodyDark.opacity(0.6)))
    }

    private func confirmButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.black))
                .dynamicTypeSize(.large ... .accessibility5)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Yes" ? "Yes, do it" : "No, cancel")
    }

    private var whatsItSayButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            client.read()
            client.talkMessage = "Asking your Mac what's on screen…"
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder").font(.system(size: 20, weight: .bold))
                Text("What does it say?")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .dynamicTypeSize(.large ... .accessibility3)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Snes.blue))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What does it say")
        .accessibilityHint("Double tap to have Clicky describe what's on your Mac's screen")
        .disabled(talkRecording)
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

    private var whatsappPad: some View {
        VStack(spacing: 10) {
            padSection(title: "CHATS", subtitle: "Open → Reply (speak, tap again to stop) → check it → Send · Photo attaches from your library") {
                VStack(spacing: 8) {
                    whatsappRow(.test)
                    whatsappRow(.vip)
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

    /// Clicky toggle: bring the Mac panel up (e.g. to see what was typed), tap again to collapse it.
    private var clickyPill: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            client.collapse()
            statusText = "Clicky toggled on your Mac — tap again to collapse / bring back"
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .bold))
                Text("CLICKY")
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
            padButton(icon: recording ? "stop.fill" : "mic.fill",
                      title: recording ? "Stop" : "Reply",
                      hint: recording ? "Tap when you're done talking" : "Dictate — Clicky types it there",
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

    private func whatsappReplyTapped(_ chat: WhatsAppChat) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if recorder.isListening {
            // Only the row that started the recording can stop it.
            guard recordTarget == .whatsapp, whatsappChat == chat else { return }
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
                    statusText = "Clicky toggled on your Mac — tap again to collapse / bring back"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("CLICKY")
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
                    statusText = "Clicky toggled on your Mac — tap again to collapse / bring back"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text("CLICKY")
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

            // Like / Subscribe
            HStack(spacing: 8) {
                spotifyTile("hand.thumbsup.fill", "Like", accent: Snes.youtube) { youtubeTapped("LIKE") }
                spotifyTile("bell.badge.fill", "Subscribe", accent: Snes.youtube) { youtubeTapped("SUBSCRIBE") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Collapse the browser window itself, out of the way, without pausing playback
            HStack(spacing: 8) {
                spotifyTile("arrow.down.right.and.arrow.up.left", "Collapse Browser") { youtubeTapped("COLLAPSE") }
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

    private func youtubeTapped(_ command: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        client.youtube(command)
        switch command {
        case "PLAYPAUSE": statusText = "YouTube — play / pause"
        case "SKIP_FORWARD": statusText = "YouTube — skip forward 10s"
        case "SKIP_BACK": statusText = "YouTube — skip back 10s"
        case "FULLSCREEN": statusText = "YouTube — fullscreen toggled"
        case "MUTE": statusText = "YouTube — mute toggled"
        case "LIKE": statusText = "YouTube — liked"
        case "SUBSCRIBE": statusText = "YouTube — subscribed"
        case "COLLAPSE": statusText = "YouTube — browser minimized"
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
                Text("CLICKY")
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
            let gap: CGFloat = 8
            let cols: CGFloat = 4
            // Fill the height: 6 rows; keys stretch as wide as the column allows.
            let rowH = (geo.size.height - gap * 5) / 6
            let unit = (geo.size.width - gap * (cols - 1)) / cols
            VStack(spacing: gap) {
                row([key("↑"), key("↓"), key("←"), key("→")], h: rowH, gap: gap)
                row([key("⌫"), key("="), key("/"), key("*")], h: rowH, gap: gap)
                row([key("7"), key("8"), key("9"), key("-")], h: rowH, gap: gap)
                // 4 5 6 / 1 2 3 with "+" spanning both rows.
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        row([key("4", label: askRecording ? "STOP" : "ASK",
                                 icon: askRecording ? "stop.fill" : "questionmark.bubble.fill",
                                 tint: Snes.purple, lit: true, waveform: askRecording),
                             key("5"),
                             key("6")], h: rowH, gap: gap)
                        row([key("1", label: "CAPTURE TAB", icon: "rectangle.on.rectangle", tint: Snes.yellow, lit: true),
                             key("2", label: "CAPTURE", icon: "camera.viewfinder", tint: Snes.blue, lit: true),
                             key("3", label: dictateRecording ? "STOP" : "DICTATE",
                                 icon: dictateRecording ? "stop.fill" : "mic.fill",
                                 tint: Snes.red, lit: true, waveform: dictateRecording)], h: rowH, gap: gap)
                    }
                    key("+", h: rowH * 2 + gap, w: unit)
                }
                // Clicky toggle (double-wide), ".", collapse
                HStack(spacing: gap) {
                    key("0", label: "CLICKY  show / hide", icon: "sparkles", h: rowH, w: unit * 2 + gap, small: true)
                    key(".", h: rowH, w: unit)
                    key("enter", label: "COLLAPSE", icon: "chevron.down.circle", h: rowH, w: unit, small: true)
                }
            }
        }
    }

    private func row(_ keys: [some View], h: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { $0.element.frame(height: h) }
        }
    }

    /// SNES-style key. `id` is what the key *does*; `label` is what it shows.
    /// A `tint` makes it one of the coloured controller buttons; `lit` toggles
    /// between the saturated gem colour and a dimmed version.
    private func key(_ id: String, label: String? = nil, icon: String? = nil, tint: Color? = nil, lit: Bool = false,
                     h: CGFloat? = nil, w: CGFloat? = nil, small: Bool = false,
                     waveform: Bool = false,
                     action: ((String) -> Void)? = nil) -> some View {
        let colored = tint != nil
        let face: Color = tint.map { lit ? $0 : $0.opacity(0.45) } ?? Snes.key
        // Keys with an icon show icon + short caption; the rest show a big glyph.
        let captioned = icon != nil
        return Button {
            (action ?? tapped)(id)
        } label: {
            ZStack {
                if waveform {
                    // Live mic level bars behind the label while recording.
                    WaveformView(level: recorder.level, bars: 16,
                                 color: .white.opacity(0.55), maxHeight: 34)
                        .padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }
                if captioned {
                    VStack(spacing: 3) {
                        Image(systemName: icon ?? "")
                            .font(.system(size: small ? 18 : 22, weight: .bold))
                        Text(label ?? id)
                            .font(.system(size: small ? 11 : 12, design: .monospaced).weight(.black))
                            .kerning(0.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, 6)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: label)
                    .foregroundStyle(colored ? Color.white : Snes.text)
                    .shadow(color: .black.opacity(colored ? 0.4 : 0), radius: 1, y: 1)
                } else {
                    Text(label ?? id)
                    .font(.system(small ? .title3 : .title, design: .monospaced).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(colored ? Color.white : Snes.text)
                    .shadow(color: .black.opacity(colored ? 0.4 : 0), radius: 1, y: 1)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [face.opacity(colored ? 1 : 1).lighter(colored ? 0.18 : 0.10), face],
                            startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                        .overlay(
                            // Glossy highlight along the top edge, like moulded plastic.
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                     startPoint: .top, endPoint: .center))
                                .padding(1)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 3)
                )
        }
        .buttonStyle(.plain)
        .frame(width: w, height: h)
    }

    // MARK: - Actions

    private var askRecording: Bool { recorder.isListening && recordTarget == .ask }
    private var dictateRecording: Bool { recorder.isListening && recordTarget == .dictate }
    private var whatsappRecording: Bool { recorder.isListening && recordTarget == .whatsapp }
    private var talkRecording: Bool { recorder.isListening && recordTarget == .talk }

    private func talkTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if recorder.isListening {
            // Only the TALK button itself can stop a TALK recording.
            guard recordTarget == .talk else { return }
        } else {
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
            // Toggle: the Mac shows Clicky if hidden/collapsed, collapses it if open.
            client.collapse()
            statusText = "Clicky toggled — tap CLICKY again to hide or bring it back"
        case "4":
            // Ask record. Tapping while a dictation is running stops that instead.
            if !recorder.isListening { dictateMode = false; recordTarget = .ask }
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
            // Dictate record. Tapping while an Ask recording is running stops that instead.
            if !recorder.isListening {
                dictateMode = true
                recordTarget = .dictate
                client.show()
                client.tab("DICTATE")
            }
            toggleListening()
        case "enter":
            client.collapse()
            statusText = "Clicky collapsed on your Mac"
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
                    statusText = "Sent to Clicky: “\(text)”"
                }
            }
        } else {
            guard !permissionDenied else { return }
            do {
                try recorder.start()
                recorder.onPartial = { [client] text in client.partial(text) }
                if recordTarget != .whatsapp { client.listen() }
                switch recordTarget {
                case .whatsapp: statusText = "Listening… speak your reply, then tap Stop"
                case .dictate: statusText = "Listening… speak, then tap STOP to copy to your Mac"
                case .ask: statusText = "Listening… speak, then tap STOP to ask"
                case .talk: statusText = "Listening… say what you want Clicky to do, then tap Stop"
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
