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
}
