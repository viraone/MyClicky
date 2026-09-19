import AppKit

/// How burned-in subtitles look. One style for the whole project, sized for
/// a 1080×1920 frame and kept clear of the strips TikTok and Instagram
/// cover with their own controls.
struct CaptionStyle: Equatable {
    enum Face: Equatable {
        case system(NSFont.Weight)
        case rounded(NSFont.Weight)
        /// Tall, tight capitals — the "impact" look.
        case condensed
        case serif
    }

    var face: Face = .system(.heavy)
    var fontSize: CGFloat = 64
    var italic = false
    var uppercase = false
    var textColor = NSColor.white
    /// The colour of the word being spoken, or nil to leave every word alike.
    var accentColor: NSColor? = nil
    /// The box behind the text, or nil for bare text on the video.
    var pillColor: NSColor? = NSColor.black.withAlphaComponent(0.65)
    var cornerRadius: CGFloat = 20
    var strokeColor: NSColor? = nil
    /// Outline thickness in frame pixels, drawn behind the letters.
    var strokeWidth: CGFloat = 0
    var shadowColor: NSColor? = nil
    var shadowRadius: CGFloat = 0
    var shadowOffset = CGSize.zero
    var horizontalPadding: CGFloat = 32
    var verticalPadding: CGFloat = 18
    /// Widest a caption may be, as a share of the frame width.
    var maxWidthShare: CGFloat = 0.84
    /// Where the caption's centre sits, as a share of the frame height from
    /// the bottom. 0.30 clears the ~350px caption/controls strip at the foot
    /// of a Reel and still reads as "lower third".
    var centreFromBottom: CGFloat = 0.30

    var font: NSFont {
        var base: NSFont
        var slanted = false
        switch face {
        case .system(let weight):
            base = NSFont.systemFont(ofSize: fontSize, weight: weight)
        case .rounded(let weight):
            let system = NSFont.systemFont(ofSize: fontSize, weight: weight)
            base = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? system
        case .condensed:
            base = NSFont(name: "AvenirNextCondensed-Heavy", size: fontSize)
                ?? NSFont(name: "Futura-CondensedExtraBold", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize, weight: .black)
        case .serif:
            base = NSFont(name: italic ? "Georgia-BoldItalic" : "Georgia-Bold", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
            slanted = italic
        }
        if italic && !slanted {
            let traits = base.fontDescriptor.symbolicTraits.union(.italic)
            base = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: fontSize) ?? base
        }
        return base
    }

    /// The text as this style spells it.
    func display(_ text: String) -> String { uppercase ? text.uppercased() : text }
}

/// The subtitle looks a project can pick from — VEED's Social / Business /
/// Retro shelves, drawn by Peeky's own renderer so what's picked is exactly
/// what's exported. Saved by `rawValue`, so names are forever.
enum SubtitleStylePreset: String, CaseIterable, Identifiable, Codable {
    // Social
    case clean, pop, paper, comic, neon, mint
    // Business
    case boxed, soft, outline, glow, slate, caps
    // Retro
    case sunsetItalic, blackBox, sunshine, inkItalic, lemon, serif

    enum Category: String, CaseIterable, Identifiable {
        case social = "Social", business = "Business", retro = "Retro"
        var id: String { rawValue }
        var presets: [SubtitleStylePreset] { SubtitleStylePreset.allCases.filter { $0.category == self } }
    }

    static let `default` = SubtitleStylePreset.clean
    /// The words every style tile is drawn with.
    static let sampleText = "Just like this"

    var id: String { rawValue }

    var category: Category {
        switch self {
        case .clean, .pop, .paper, .comic, .neon, .mint: .social
        case .boxed, .soft, .outline, .glow, .slate, .caps: .business
        case .sunsetItalic, .blackBox, .sunshine, .inkItalic, .lemon, .serif: .retro
        }
    }

    var name: String {
        switch self {
        case .clean: "Clean"
        case .pop: "Pop"
        case .paper: "Paper"
        case .comic: "Comic"
        case .neon: "Neon"
        case .mint: "Mint"
        case .boxed: "Boxed"
        case .soft: "Soft"
        case .outline: "Outline"
        case .glow: "Glow"
        case .slate: "Slate"
        case .caps: "Caps"
        case .sunsetItalic: "Sunset"
        case .blackBox: "Black box"
        case .sunshine: "Sunshine"
        case .inkItalic: "Ink"
        case .lemon: "Lemon"
        case .serif: "Serif"
        }
    }

    var style: CaptionStyle {
        var s = CaptionStyle()
        let ink = NSColor.black
        let softShadow: (CaptionStyle) -> CaptionStyle = { var c = $0; c.shadowColor = ink.withAlphaComponent(0.8); c.shadowRadius = 10; c.shadowOffset = CGSize(width: 0, height: -3); return c }
        switch self {
        case .clean:
            break
        case .pop:
            s.face = .rounded(.heavy); s.pillColor = nil
            s.accentColor = NSColor(red: 1.0, green: 0.62, blue: 0.72, alpha: 1)
            s = softShadow(s)
        case .paper:
            s.face = .system(.bold); s.textColor = ink; s.pillColor = .white; s.cornerRadius = 12
        case .comic:
            s.face = .condensed; s.fontSize = 92; s.italic = true; s.uppercase = true; s.pillColor = nil
            s.strokeColor = ink; s.strokeWidth = 14; s.maxWidthShare = 0.7
            s.accentColor = NSColor(red: 0.52, green: 0.56, blue: 1.0, alpha: 1)
        case .neon:
            s.face = .condensed; s.fontSize = 84; s.uppercase = true; s.pillColor = nil
            s.strokeColor = ink; s.strokeWidth = 10
            s.accentColor = NSColor(red: 1.0, green: 0.3, blue: 0.85, alpha: 1)
        case .mint:
            s.face = .system(.black); s.fontSize = 72; s.uppercase = true; s.pillColor = nil
            s.strokeColor = ink; s.strokeWidth = 12
            s.accentColor = NSColor(red: 0.6, green: 1.0, blue: 0.7, alpha: 1)
        case .boxed:
            s.face = .system(.semibold); s.pillColor = NSColor(white: 0.16, alpha: 0.9); s.cornerRadius = 6
        case .soft:
            s.face = .system(.bold); s.pillColor = nil; s = softShadow(s)
        case .outline:
            s.face = .system(.bold); s.pillColor = nil; s.strokeColor = ink; s.strokeWidth = 6
        case .glow:
            s.face = .system(.bold); s.pillColor = nil
            s.shadowColor = NSColor.white.withAlphaComponent(0.9); s.shadowRadius = 18
        case .slate:
            s.face = .system(.bold); s.pillColor = NSColor(white: 0.25, alpha: 0.8); s.cornerRadius = 8
        case .caps:
            s.face = .system(.heavy); s.uppercase = true; s.pillColor = nil; s = softShadow(s)
        case .sunsetItalic:
            s.face = .system(.bold); s.italic = true; s.pillColor = nil
            s.textColor = NSColor(red: 1.0, green: 0.92, blue: 0.3, alpha: 1); s.strokeColor = ink; s.strokeWidth = 6
        case .blackBox:
            s.face = .system(.bold); s.pillColor = ink; s.cornerRadius = 4
        case .sunshine:
            s.face = .system(.heavy); s.pillColor = nil
            s.textColor = NSColor(red: 1.0, green: 0.92, blue: 0.3, alpha: 1); s.strokeColor = ink; s.strokeWidth = 10
        case .inkItalic:
            s.face = .system(.medium); s.italic = true; s.pillColor = ink; s.cornerRadius = 4
        case .lemon:
            s.face = .system(.bold); s.pillColor = ink; s.cornerRadius = 4
            s.textColor = NSColor(red: 0.62, green: 0.62, blue: 0.3, alpha: 1)
            s.accentColor = NSColor(red: 1.0, green: 0.95, blue: 0.35, alpha: 1)
        case .serif:
            s.face = .serif; s.italic = true; s.pillColor = nil; s.strokeColor = ink; s.strokeWidth = 8
        }
        return s
    }

    /// Which word the tile lights up, for styles that follow the speaker.
    var sampleHighlight: Int? { style.accentColor == nil ? nil : 2 }
}
