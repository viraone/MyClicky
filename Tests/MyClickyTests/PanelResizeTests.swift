import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class PanelResizeTests: XCTestCase {
    let start = NSRect(x: 200, y: 150, width: 600, height: 400)
    let minimum = NSSize(width: 300, height: 200)
    let maximum = NSSize(width: 1200, height: 900)
    let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)

    func testTopEdgePreservesBottomAndWidth() {
        for (y, height) in [(650.0, 500.0), (450, 300), (0, 200), (2000, 850)] {
            let frame = PanelResizeCorner.top.resizedFrame(from: start, dragged: .init(x: -100, y: y),
                                                          minimum: minimum, maximum: maximum, visible: visible)
            XCTAssertEqual(frame, NSRect(x: 200, y: 150, width: 600, height: height))
        }
        XCTAssertTrue(PanelResizeCorner.top.isEdge)
        XCTAssertEqual(PanelResizeCorner.top.anchor(in: start), NSPoint(x: 200, y: 150))
        XCTAssertEqual(PanelResizeCorner.top.point(in: start), NSPoint(x: 800, y: 550))
    }

    func testTopEdgeUsesOffsetDisplayAndMaximumHeight() {
        let screen = NSRect(x: -1600, y: 200, width: 1600, height: 1400)
        let frame = PanelResizeCorner.top.resizedFrame(from: .init(x: -1400, y: 300, width: 600, height: 400),
                                                      dragged: .init(x: 0, y: 2000), minimum: minimum,
                                                      maximum: maximum, visible: screen)
        XCTAssertEqual(frame, NSRect(x: -1400, y: 300, width: 600, height: 900))
    }

    func testExistingCornersAndEdgesKeepTheirAnchors() {
        for corner: PanelResizeCorner in [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .bottom, .leading] {
            let point = corner.point(in: start)
            let frame = corner.resizedFrame(from: start, dragged: point, minimum: minimum,
                                            maximum: maximum, visible: visible)
            XCTAssertEqual(frame, start)
        }
    }

    func testCornerAndEdgeDragsChangeOnlyTheirIntendedDimensions() {
        let cases: [(PanelResizeCorner, NSPoint, NSRect)] = [
            (.topLeading, .init(x: 100, y: 650), .init(x: 100, y: 150, width: 700, height: 500)),
            (.topTrailing, .init(x: 900, y: 650), .init(x: 200, y: 150, width: 700, height: 500)),
            (.bottomLeading, .init(x: 100, y: 50), .init(x: 100, y: 50, width: 700, height: 500)),
            (.bottomTrailing, .init(x: 900, y: 50), .init(x: 200, y: 50, width: 700, height: 500)),
            (.bottom, .init(x: 800, y: 50), .init(x: 200, y: 50, width: 600, height: 500)),
            (.leading, .init(x: 100, y: 150), .init(x: 100, y: 150, width: 700, height: 400))
        ]
        for (corner, point, expected) in cases {
            XCTAssertEqual(corner.resizedFrame(from: start, dragged: point, minimum: minimum,
                                               maximum: maximum, visible: visible), expected)
        }
    }

    func testTopDragFinishesOnceOnCancellationOrDismantle() {
        let view = PanelTopResizeHandle.ResizeView()
        var ends = 0
        view.onResize = { if $0 == nil { ends += 1 } }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
        view.cancelOperation(nil)
        view.finishDrag()
        XCTAssertEqual(ends, 1)
        view.mouseDown(with: event)
        PanelTopResizeHandle.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(ends, 2)
    }
}
