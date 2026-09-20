import CoreGraphics

/// The shape of the finished video — a social-media preset like VEED's
/// frame picker: which platform it's for, its aspect ratio, and the pixel
/// size it's rendered at. The preview canvas, the caption layout and the
/// export all follow the project's format.
struct FrameFormat: Identifiable, Hashable {
    let id: String
    let platform: String
    let ratio: String
    /// An SF Symbol standing in for the platform's mark.
    let symbol: String
    let renderSize: CGSize

    var name: String { "\(platform) · \(ratio)" }
    var aspect: CGFloat { renderSize.width / renderSize.height }
    var pixels: String { "\(Int(renderSize.width)) × \(Int(renderSize.height))" }
    var isPortrait: Bool { renderSize.height > renderSize.width }

    private static let portrait = CGSize(width: 1080, height: 1920)
    private static let landscape = CGSize(width: 1920, height: 1080)
    private static let square = CGSize(width: 1080, height: 1080)

    static let all: [FrameFormat] = [
        FrameFormat(id: "instagram-reel", platform: "Instagram Reel", ratio: "9:16", symbol: "camera.fill", renderSize: portrait),
        FrameFormat(id: "tiktok", platform: "TikTok", ratio: "9:16", symbol: "music.note", renderSize: portrait),
        FrameFormat(id: "youtube-shorts", platform: "YouTube Shorts", ratio: "9:16", symbol: "play.rectangle.fill", renderSize: portrait),
        FrameFormat(id: "youtube", platform: "YouTube", ratio: "16:9", symbol: "play.rectangle.fill", renderSize: landscape),
        FrameFormat(id: "instagram-reel-ultra-wide", platform: "Instagram Reel Ultra Wide", ratio: "32:9", symbol: "camera.fill",
                    renderSize: CGSize(width: 3840, height: 1080)),
        FrameFormat(id: "instagram-story", platform: "Instagram Story", ratio: "9:16", symbol: "circle.dashed", renderSize: portrait),
        FrameFormat(id: "instagram-post", platform: "Instagram Post", ratio: "1:1", symbol: "camera.fill", renderSize: square),
        FrameFormat(id: "instagram-post-4-5", platform: "Instagram Post", ratio: "4:5", symbol: "camera.fill",
                    renderSize: CGSize(width: 1080, height: 1350)),
        FrameFormat(id: "linkedin-9-16", platform: "LinkedIn", ratio: "9:16", symbol: "briefcase.fill", renderSize: portrait),
        FrameFormat(id: "linkedin-1-1", platform: "LinkedIn", ratio: "1:1", symbol: "briefcase.fill", renderSize: square),
        FrameFormat(id: "linkedin-16-9", platform: "LinkedIn", ratio: "16:9", symbol: "briefcase.fill", renderSize: landscape),
        FrameFormat(id: "x-1-1", platform: "X (Twitter)", ratio: "1:1", symbol: "xmark", renderSize: square),
        FrameFormat(id: "x-3-4", platform: "X (Twitter)", ratio: "3:4", symbol: "xmark", renderSize: CGSize(width: 1080, height: 1440)),
        FrameFormat(id: "x-16-9", platform: "X (Twitter)", ratio: "16:9", symbol: "xmark", renderSize: landscape),
        FrameFormat(id: "facebook-9-16", platform: "Facebook Video", ratio: "9:16", symbol: "person.2.fill", renderSize: portrait),
        FrameFormat(id: "facebook-1-1", platform: "Facebook Video", ratio: "1:1", symbol: "person.2.fill", renderSize: square),
        FrameFormat(id: "facebook-16-9", platform: "Facebook Video", ratio: "16:9", symbol: "person.2.fill", renderSize: landscape),
        FrameFormat(id: "pinterest", platform: "Pinterest", ratio: "2:3", symbol: "pin.fill", renderSize: CGSize(width: 1000, height: 1500)),
        FrameFormat(id: "snapchat", platform: "Snapchat", ratio: "9:16", symbol: "bolt.fill", renderSize: portrait),
    ]

    /// Reels: what every project was before the picker existed.
    static let `default` = all[0]

    static func named(_ id: String) -> FrameFormat {
        all.first { $0.id == id } ?? .default
    }

    /// The presets whose platform or ratio contains `query`, or all of
    /// them for an empty search.
    static func matching(_ query: String) -> [FrameFormat] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.platform.localizedCaseInsensitiveContains(trimmed) || $0.ratio.contains(trimmed)
        }
    }
}
