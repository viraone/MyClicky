import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

actor ScreenCaptureService {
    /// Captures `screen` and crops to `rect`, both expressed in AppKit screen
    /// coordinates (points, origin bottom-left, matching `NSScreen.frame`).
    func captureCropped(rect: CGRect, screen: NSScreen) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // Convert from bottom-left-origin screen points to top-left-origin pixels.
        let localX = (rect.minX - screen.frame.minX) * scale
        let localYFromTop = (screen.frame.maxY - rect.maxY) * scale
        let pixelRect = CGRect(x: localX, y: localYFromTop, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width > 0, pixelRect.height > 0, let cropped = image.cropping(to: pixelRect) else {
            throw CaptureError.encodingFailed
        }
        guard let data = Self.pngData(from: cropped) else { throw CaptureError.encodingFailed }
        return data
    }

    /// Captures the full display and returns a downscaled JPEG suitable for
    /// sending to a vision model.
    func captureDisplayJPEG(screen: NSScreen, maxDimension: CGFloat = 1600, quality: CGFloat = 0.7) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let scaled = Self.downscale(image, maxDimension: maxDimension) ?? image
        guard let data = Self.jpegData(from: scaled, quality: quality) else {
            throw CaptureError.encodingFailed
        }
        return data
    }

    private static func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxDimension else { return image }
        let ratio = maxDimension / longest
        let newWidth = Int(width * ratio)
        let newHeight = Int(height * ratio)
        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    enum CaptureError: LocalizedError {
        case noDisplay, encodingFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay: "Could not find the selected display."
            case .encodingFailed: "Could not encode the screen capture."
            }
        }
    }
}
