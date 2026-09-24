import AppKit
import SwiftUI

/// An sRGB colour that survives JSON, which SwiftUI's `Color` does not.
struct CaptureBackgroundColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`, the way the presets are written.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(_ color: NSColor) {
        // Pattern and catalog colours can't report components; treat them as black.
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        self.init(
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: srgb.alphaComponent
        )
    }

    init(_ color: Color) {
        self.init(NSColor(color))
    }

    var appKit: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// The "pretty screenshot" backdrop: padding around the capture, a solid or
/// gradient fill behind it, a drop shadow and rounded corners on the capture.
/// Lengths are in output pixels so the export is the source of truth and the
/// on-screen preview scales the whole composition down to fit.
struct CaptureBackgroundStyle: Codable, Equatable {
    enum Fill: Codable, Equatable {
        case none
        case solid(CaptureBackgroundColor)
        /// `angle` is in degrees, clockwise from left-to-right on screen:
        /// 0 runs left→right, 90 runs top→bottom, 45 runs top-left→bottom-right.
        case gradient(start: CaptureBackgroundColor, end: CaptureBackgroundColor, angle: Double)

        enum Kind: String, CaseIterable, Identifiable {
            case none
            case solid
            case gradient

            var id: String { rawValue }

            var label: String {
                switch self {
                case .none: "None"
                case .solid: "Solid"
                case .gradient: "Gradient"
                }
            }
        }

        var kind: Kind {
            switch self {
            case .none: .none
            case .solid: .solid
            case .gradient: .gradient
            }
        }

        /// Switches the fill type while keeping whatever colour is already chosen.
        func converted(to kind: Kind) -> Fill {
            switch (kind, self) {
            case (.none, _):
                return .none
            case (.solid, .solid), (.gradient, .gradient):
                return self
            case (.solid, .gradient(let start, _, _)):
                return .solid(start)
            case (.solid, .none):
                return .solid(CaptureBackgroundStyle.defaultSolid)
            case (.gradient, .solid(let color)):
                return .gradient(start: color, end: CaptureBackgroundStyle.defaultGradientEnd, angle: 45)
            case (.gradient, .none):
                return CaptureBackgroundStyle.defaultGradient
            }
        }
    }

    static let paddingRange: ClosedRange<CGFloat> = 0...200
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...40

    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 12
    var shadow = true
    var shadowRadius: CGFloat = 24
    var shadowOpacity: Double = 0.35
    /// Positive `height` moves the shadow down, as on screen.
    var shadowOffset = CGSize(width: 0, height: 8)
    var fill: Fill = .none

    init(
        padding: CGFloat = 48,
        cornerRadius: CGFloat = 12,
        shadow: Bool = true,
        shadowRadius: CGFloat = 24,
        shadowOpacity: Double = 0.35,
        shadowOffset: CGSize = CGSize(width: 0, height: 8),
        fill: Fill = .none
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.shadowOffset = shadowOffset
        self.fill = fill
    }

    /// The capture exactly as grabbed: no padding, fill, shadow or rounding.
    static let plain = CaptureBackgroundStyle(padding: 0, cornerRadius: 0, shadow: false, fill: .none)

    /// False when export is pixel-for-pixel what it was before backgrounds existed.
    /// A shadow alone never shows: with no padding or rounding it falls outside the image.
    var changesOutput: Bool {
        padding > 0 || cornerRadius > 0 || fill != .none
    }

    /// A shadow needs somewhere to fall: padding, or the corner cut-outs.
    var castsShadow: Bool {
        shadow && (padding > 0 || cornerRadius > 0)
    }

    /// Whole-pixel padding inside the allowed ranges, whatever was persisted.
    var clamped: CaptureBackgroundStyle {
        var style = self
        style.padding = min(max(padding.rounded(), Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
        style.cornerRadius = min(max(cornerRadius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        style.shadowRadius = max(0, shadowRadius)
        style.shadowOpacity = min(max(shadowOpacity, 0), 1)
        return style
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case padding, cornerRadius, shadow, shadowRadius, shadowOpacity, shadowOffset, fill
    }

    /// Missing keys fall back to the defaults so older saved styles keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaptureBackgroundStyle()
        padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding) ?? defaults.padding
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? defaults.shadow
        shadowRadius = try container.decodeIfPresent(CGFloat.self, forKey: .shadowRadius) ?? defaults.shadowRadius
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? defaults.shadowOpacity
        shadowOffset = try container.decodeIfPresent(CGSize.self, forKey: .shadowOffset) ?? defaults.shadowOffset
        fill = try container.decodeIfPresent(Fill.self, forKey: .fill) ?? defaults.fill
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(shadowRadius, forKey: .shadowRadius)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(shadowOffset, forKey: .shadowOffset)
        try container.encode(fill, forKey: .fill)
    }
}

// MARK: - Presets

struct CaptureBackgroundPreset: Identifiable, Equatable {
    let name: String
    let style: CaptureBackgroundStyle

    var id: String { name }
}

extension CaptureBackgroundStyle {
    static let defaultSolid = CaptureBackgroundColor(hex: 0x2A2A2E)
    static let defaultGradientEnd = CaptureBackgroundColor(hex: 0x4C1D95)
    static let defaultGradient = Fill.gradient(
        start: CaptureBackgroundColor(hex: 0x0F172A),
        end: defaultGradientEnd,
        angle: 45
    )

    static let presets: [CaptureBackgroundPreset] = [
        CaptureBackgroundPreset(name: "None", style: .plain),
        CaptureBackgroundPreset(name: "Midnight", style: CaptureBackgroundStyle(fill: defaultGradient)),
        CaptureBackgroundPreset(name: "Sunset", style: CaptureBackgroundStyle(fill: .gradient(
            start: CaptureBackgroundColor(hex: 0xF97316),
            end: CaptureBackgroundColor(hex: 0xEC4899),
            angle: 45
        ))),
        CaptureBackgroundPreset(name: "Ocean", style: CaptureBackgroundStyle(fill: .gradient(
            start: CaptureBackgroundColor(hex: 0x0EA5E9),
            end: CaptureBackgroundColor(hex: 0x1E3A8A),
            angle: 135
        ))),
        CaptureBackgroundPreset(name: "Mint", style: CaptureBackgroundStyle(fill: .gradient(
            start: CaptureBackgroundColor(hex: 0xA7F3D0),
            end: CaptureBackgroundColor(hex: 0x5EEAD4),
            angle: 90
        ))),
        CaptureBackgroundPreset(name: "Mono", style: CaptureBackgroundStyle(fill: .solid(defaultSolid))),
    ]
}

// MARK: - Gradient geometry

extension CaptureBackgroundStyle {
    /// The line a gradient runs along, in a top-left coordinate space. It passes
    /// through the centre and is just long enough to reach the far corners, so
    /// the start and end colours land exactly in the corners like CSS gradients.
    /// The preview and the export both draw from these points, so they agree
    /// on non-square images where unit-point gradients would skew.
    static func gradientLine(angle: Double, in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        let direction = CGPoint(x: cos(radians), y: sin(radians))
        let length = abs(rect.width * direction.x) + abs(rect.height * direction.y)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = CGPoint(x: direction.x * length / 2, y: direction.y * length / 2)
        return (
            start: CGPoint(x: center.x - half.x, y: center.y - half.y),
            end: CGPoint(x: center.x + half.x, y: center.y + half.y)
        )
    }

    /// The same direction as unit points, good enough for a square swatch.
    static func gradientUnitPoints(angle: Double) -> (start: UnitPoint, end: UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return (
            start: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            end: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}

// MARK: - Persistence

extension CaptureBackgroundStyle {
    static let defaultsKey = "captureBackgroundStyle"

    /// The style from the last capture, or `.plain` until one has been chosen.
    static func lastUsed(from defaults: UserDefaults = .standard) -> CaptureBackgroundStyle {
        guard let data = defaults.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(CaptureBackgroundStyle.self, from: data) else {
            return .plain
        }
        return style.clamped
    }

    func saveAsLastUsed(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Layout

/// Where the capture sits inside the exported image, in output pixels with a
/// top-left origin like the editor's normalized annotation space.
struct CaptureBackgroundLayout: Equatable {
    let imageSize: CGSize
    let padding: CGFloat

    init(imageSize: CGSize, style: CaptureBackgroundStyle) {
        self.imageSize = imageSize
        padding = style.clamped.padding
    }

    var outputSize: CGSize {
        CGSize(width: imageSize.width + padding * 2, height: imageSize.height + padding * 2)
    }

    var screenshotRect: CGRect {
        CGRect(origin: CGPoint(x: padding, y: padding), size: imageSize)
    }

    /// The whole composition scaled to `width` for the on-screen preview, so
    /// padding shrinks with the capture and matches the export proportionally.
    func fitted(toWidth width: CGFloat) -> CaptureMarkupPreviewLayout {
        let output = outputSize
        guard output.width > 0, output.height > 0, width > 0 else { return .empty }
        let scale = width / output.width
        return CaptureMarkupPreviewLayout(
            compositionSize: CGSize(width: width, height: output.height * scale),
            screenshotFrame: CGRect(
                x: padding * scale,
                y: padding * scale,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            ),
            scale: scale
        )
    }
}

struct CaptureMarkupPreviewLayout: Equatable {
    var compositionSize: CGSize
    var screenshotFrame: CGRect
    var scale: CGFloat

    static let empty = CaptureMarkupPreviewLayout(compositionSize: .zero, screenshotFrame: .zero, scale: 0)
}
