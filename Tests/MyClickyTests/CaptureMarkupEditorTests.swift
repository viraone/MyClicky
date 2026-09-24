import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class CaptureMarkupEditorTests: XCTestCase {
    func testAspectFitCentersImageWithoutChangingItsRatio() {
        let rect = CaptureMarkupEditor.aspectFit(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 300, height: 300)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    func testWidthFitUsesAllHorizontalSpaceAndPreservesRatio() {
        let size = CaptureMarkupEditor.widthFit(
            imageSize: CGSize(width: 200, height: 100),
            width: 600
        )

        XCTAssertEqual(size, CGSize(width: 600, height: 300))
    }

    func testRendererPreservesResolutionAndDrawsMarkup() throws {
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        image.unlockFocus()

        let annotation = CaptureMarkupAnnotation(
            kind: .rectangle(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)),
            color: .red
        )
        var sourceRect = CGRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil))
        let rendered = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [annotation]))
        var rect = CGRect(origin: .zero, size: rendered.size)
        let cgImage = try XCTUnwrap(rendered.cgImage(forProposedRect: &rect, context: nil, hints: nil))

        XCTAssertEqual(cgImage.width, source.width)
        XCTAssertEqual(cgImage.height, source.height)

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let edge = try XCTUnwrap(bitmap.colorAt(x: cgImage.width / 10, y: cgImage.height / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(edge.redComponent, 0.8)
        XCTAssertLessThan(edge.greenComponent, 0.4)
        XCTAssertLessThan(edge.blueComponent, 0.4)
    }

    func testArrowCanBeSelectedAnywhereInsideItsMoveOutline() {
        let arrow = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)),
            color: .red
        )

        XCTAssertTrue(CaptureMarkupInteraction.hitTest(arrow, at: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(CaptureMarkupInteraction.hitTest(arrow, at: CGPoint(x: 0.5, y: 0.7)))
        XCTAssertFalse(CaptureMarkupInteraction.hitTest(arrow, at: CGPoint(x: 0.1, y: 0.9)))
    }

    func testMovingArrowKeepsItInsideImage() throws {
        let arrow = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.9, y: 0.9)),
            color: .red
        )
        let moved = CaptureMarkupInteraction.translated(arrow, by: CGPoint(x: 0.5, y: 0.5))

        guard case .arrow(let start, let end) = moved.kind else {
            return XCTFail("Expected an arrow")
        }
        XCTAssertEqual(start.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(start.y, 0.8, accuracy: 0.0001)
        XCTAssertEqual(end.x, 1, accuracy: 0.0001)
        XCTAssertEqual(end.y, 1, accuracy: 0.0001)
    }

    func testSelectedArrowKeepsControlOnTheNextDragAnywhereOnCanvas() throws {
        let selected = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)),
            color: .red
        )
        let overlapping = CaptureMarkupAnnotation(
            kind: .rectangle(CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)),
            color: .cyan
        )

        let match = CaptureMarkupInteraction.annotationToMove(
            in: [selected, overlapping],
            selectedID: selected.id,
            at: CGPoint(x: 0.95, y: 0.05)
        )

        XCTAssertEqual(match?.id, selected.id)
    }

    func testArrowEndpointHandlesChooseTheClosestEnd() {
        let arrow = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)),
            color: .red
        )
        let canvas = CGSize(width: 1_000, height: 500)

        XCTAssertEqual(
            CaptureMarkupInteraction.dragTarget(
                for: arrow,
                at: CGPoint(x: 0.205, y: 0.305),
                canvasSize: canvas
            ),
            .arrowStart
        )
        XCTAssertEqual(
            CaptureMarkupInteraction.dragTarget(
                for: arrow,
                at: CGPoint(x: 0.795, y: 0.695),
                canvasSize: canvas
            ),
            .arrowEnd
        )
        XCTAssertEqual(
            CaptureMarkupInteraction.dragTarget(
                for: arrow,
                at: CGPoint(x: 0.5, y: 0.5),
                canvasSize: canvas
            ),
            .move
        )
    }

    func testDraggingArrowTipRotatesAndResizesAroundTail() throws {
        let arrow = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)),
            color: .red
        )
        let adjusted = CaptureMarkupInteraction.adjusted(
            arrow,
            target: .arrowEnd,
            dragStart: CGPoint(x: 0.8, y: 0.7),
            current: CGPoint(x: 0.4, y: 0.1)
        )

        guard case .arrow(let start, let end) = adjusted.kind else {
            return XCTFail("Expected an arrow")
        }
        XCTAssertEqual(start.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(start.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(end.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(end.y, 0.1, accuracy: 0.0001)
    }

    // MARK: - Backgrounds

    func testBackgroundLayoutAddsPaddingOnEverySide() {
        let layout = CaptureBackgroundLayout(
            imageSize: CGSize(width: 200, height: 100),
            style: CaptureBackgroundStyle(padding: 50)
        )

        XCTAssertEqual(layout.outputSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(layout.screenshotRect, CGRect(x: 50, y: 50, width: 200, height: 100))
    }

    func testPreviewLayoutScalesPaddingTogetherWithTheCapture() {
        let preview = CaptureBackgroundLayout(
            imageSize: CGSize(width: 200, height: 100),
            style: CaptureBackgroundStyle(padding: 50)
        ).fitted(toWidth: 600)

        XCTAssertEqual(preview.scale, 2)
        XCTAssertEqual(preview.compositionSize, CGSize(width: 600, height: 400))
        XCTAssertEqual(preview.screenshotFrame, CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    func testRenderedOutputGrowsByTwiceThePadding() throws {
        let image = try makeImage(width: 200, height: 100, fill: .white)
        let style = CaptureBackgroundStyle(padding: 40, fill: .solid(CaptureBackgroundColor(hex: 0x0000FF)))

        let rendered = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [], background: style))
        let bitmap = try bitmap(of: rendered)

        XCTAssertEqual(bitmap.pixelsWide, 280)
        XCTAssertEqual(bitmap.pixelsHigh, 180)
        XCTAssertEqual(rendered.size, NSSize(width: 280, height: 180))
    }

    func testAnnotationsMoveWithTheCaptureWhenPaddingIsAdded() throws {
        let image = try makeImage(width: 200, height: 100, fill: .white)
        let annotation = CaptureMarkupAnnotation(
            kind: .rectangle(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)),
            color: .red
        )
        let style = CaptureBackgroundStyle(
            padding: 40,
            cornerRadius: 0,
            shadow: false,
            fill: .solid(CaptureBackgroundColor(hex: 0x0000FF))
        )

        let rendered = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [annotation], background: style))
        let bitmap = try bitmap(of: rendered)

        // The box's left edge sits at 10% of the capture, shifted right by the padding.
        let edge = try color(in: bitmap, x: 40 + 20, y: 40 + 50)
        XCTAssertGreaterThan(edge.redComponent, 0.8)
        XCTAssertLessThan(edge.blueComponent, 0.4)

        // The padding is pure backdrop, never markup.
        let margin = try color(in: bitmap, x: 20, y: 90)
        XCTAssertGreaterThan(margin.blueComponent, 0.8)
        XCTAssertLessThan(margin.redComponent, 0.2)

        // Inside the capture, away from the box, the screenshot shows through.
        let inside = try color(in: bitmap, x: 140, y: 90)
        XCTAssertGreaterThan(inside.redComponent, 0.9)
        XCTAssertGreaterThan(inside.greenComponent, 0.9)
        XCTAssertGreaterThan(inside.blueComponent, 0.9)
    }

    func testPlainBackgroundRendersByteForByteLikeBefore() throws {
        let image = try makeImage(width: 200, height: 100, fill: .white) { rect in
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
        }
        let annotation = CaptureMarkupAnnotation(
            kind: .arrow(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)),
            color: .red
        )

        // The two-argument call is what every existing caller used.
        let legacy = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [annotation]))
        let plain = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [annotation], background: .plain))
        XCTAssertEqual(try pixels(of: legacy), try pixels(of: plain))
        XCTAssertEqual(try bitmap(of: plain).pixelsWide, 200)
        XCTAssertEqual(try bitmap(of: plain).pixelsHigh, 100)

        // A shadow with nothing to fall on is ignored rather than re-composited.
        let shadowOnly = CaptureBackgroundStyle(padding: 0, cornerRadius: 0, shadow: true, fill: .none)
        let shadowed = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [annotation], background: shadowOnly))
        XCTAssertEqual(try pixels(of: shadowed), try pixels(of: plain))

        // And with no markup at all the output is the pre-background drawing sequence.
        let untouched = try XCTUnwrap(CaptureMarkupRenderer.render(image: image, annotations: [], background: .plain))
        XCTAssertEqual(try pixels(of: untouched), try legacyPixels(of: image))
    }

    func testPresetsRoundTripThroughCodable() throws {
        let presets = CaptureBackgroundStyle.presets
        XCTAssertEqual(presets.count, 6)
        XCTAssertEqual(presets.first?.style, .plain)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)

        for preset in presets {
            let data = try JSONEncoder().encode(preset.style)
            let decoded = try JSONDecoder().decode(CaptureBackgroundStyle.self, from: data)
            XCTAssertEqual(decoded, preset.style, preset.name)
        }
    }

    func testDecodingFillsInMissingKeysWithDefaults() throws {
        let data = try XCTUnwrap(#"{"padding": 20}"#.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CaptureBackgroundStyle.self, from: data)

        XCTAssertEqual(decoded.padding, 20)
        XCTAssertEqual(decoded.cornerRadius, 12)
        XCTAssertTrue(decoded.shadow)
        XCTAssertEqual(decoded.fill, .none)
    }

    func testLastUsedStyleRoundTripsThroughUserDefaults() throws {
        let suite = "MyClickyTests.CaptureBackgroundStyle"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CaptureBackgroundStyle.lastUsed(from: defaults), .plain)

        var sunset = try XCTUnwrap(CaptureBackgroundStyle.presets.first { $0.name == "Sunset" }).style
        sunset.padding = 72
        sunset.saveAsLastUsed(to: defaults)

        XCTAssertEqual(CaptureBackgroundStyle.lastUsed(from: defaults), sunset)
    }

    func testPlainStyleIsTheOnlyOneThatLeavesOutputAlone() {
        XCTAssertFalse(CaptureBackgroundStyle.plain.changesOutput)
        XCTAssertFalse(CaptureBackgroundStyle(padding: 0, cornerRadius: 0, shadow: true, fill: .none).changesOutput)
        XCTAssertTrue(CaptureBackgroundStyle(padding: 1, cornerRadius: 0, shadow: false, fill: .none).changesOutput)
        XCTAssertTrue(CaptureBackgroundStyle(padding: 0, cornerRadius: 4, shadow: false, fill: .none).changesOutput)
        XCTAssertTrue(CaptureBackgroundStyle(padding: 0, cornerRadius: 0, shadow: false,
                                             fill: .solid(CaptureBackgroundColor(hex: 0x000000))).changesOutput)
    }

    func testGradientLineRunsThroughTheCentreToTheEdges() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

        let horizontal = CaptureBackgroundStyle.gradientLine(angle: 0, in: rect)
        XCTAssertEqual(horizontal.start.x, 0, accuracy: 0.0001)
        XCTAssertEqual(horizontal.start.y, 50, accuracy: 0.0001)
        XCTAssertEqual(horizontal.end.x, 200, accuracy: 0.0001)
        XCTAssertEqual(horizontal.end.y, 50, accuracy: 0.0001)

        let vertical = CaptureBackgroundStyle.gradientLine(angle: 90, in: rect)
        XCTAssertEqual(vertical.start.x, 100, accuracy: 0.0001)
        XCTAssertEqual(vertical.start.y, 0, accuracy: 0.0001)
        XCTAssertEqual(vertical.end.x, 100, accuracy: 0.0001)
        XCTAssertEqual(vertical.end.y, 100, accuracy: 0.0001)
    }

    func testSwitchingFillKindKeepsTheChosenColour() {
        let blue = CaptureBackgroundColor(hex: 0x0000FF)
        let solid = CaptureBackgroundStyle.Fill.solid(blue)

        guard case .gradient(let start, _, _) = solid.converted(to: .gradient) else {
            return XCTFail("Expected a gradient")
        }
        XCTAssertEqual(start, blue)
        XCTAssertEqual(solid.converted(to: .gradient).converted(to: .solid), solid)
        XCTAssertEqual(solid.converted(to: .none), .none)
    }

    // MARK: - Helpers

    /// A capture with an exact pixel size. `NSImage.lockFocus` would pick up
    /// the screen's backing scale and make the numbers depend on the Mac.
    private func makeImage(
        width: Int,
        height: Int,
        fill: NSColor,
        extra: ((NSRect) -> Void)? = nil
    ) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        fill.setFill()
        rect.fill()
        extra?(rect)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func bitmap(of image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    }

    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    /// Every row's pixel bytes, skipping any row padding the allocator left uninitialised.
    private func pixels(of bitmap: NSBitmapImageRep) throws -> Data {
        let base = try XCTUnwrap(bitmap.bitmapData)
        let rowBytes = bitmap.pixelsWide * bitmap.bitsPerPixel / 8
        var data = Data(capacity: rowBytes * bitmap.pixelsHigh)
        for row in 0..<bitmap.pixelsHigh {
            data.append(base.advanced(by: row * bitmap.bytesPerRow), count: rowBytes)
        }
        return data
    }

    private func pixels(of image: NSImage) throws -> Data {
        try pixels(of: bitmap(of: image))
    }

    /// The drawing sequence the renderer used before backgrounds existed, for
    /// a capture with no markup: one bitmap, one high-interpolation draw.
    private func legacyPixels(of image: NSImage) throws -> Data {
        var sourceRect = CGRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil))
        let size = NSSize(width: source.width, height: source.height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: source.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        NSImage(cgImage: source, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return try pixels(of: bitmap)
    }
}
