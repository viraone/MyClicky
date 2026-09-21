import AppKit
import SwiftUI

enum CaptureMarkupTool: String, CaseIterable {
    case select
    case arrow
    case rectangle
    case ellipse
    case draw
    case text

    var label: String {
        switch self {
        case .select: "Move"
        case .arrow: "Arrow"
        case .rectangle: "Box"
        case .ellipse: "Circle"
        case .draw: "Draw"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow.move"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .draw: "pencil.tip"
        case .text: "textformat"
        }
    }
}

enum CaptureMarkupColor: CaseIterable {
    case red
    case yellow
    case cyan
    case white
    case black

    var swiftUI: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .cyan: .cyan
        case .white: .white
        case .black: .black
        }
    }

    var appKit: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .cyan: .systemCyan
        case .white: .white
        case .black: .black
        }
    }
}

struct CaptureMarkupAnnotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGPoint, CGPoint)
        case ellipse(CGPoint, CGPoint)
        case stroke([CGPoint])
        case text(String, CGPoint)
    }

    let id: UUID
    var kind: Kind
    var color: CaptureMarkupColor

    init(id: UUID = UUID(), kind: Kind, color: CaptureMarkupColor) {
        self.id = id
        self.kind = kind
        self.color = color
    }
}

struct CaptureMarkupEditor: View {
    let image: NSImage
    let onCancel: () -> Void
    let onSave: (NSImage) -> Void

    @State private var tool: CaptureMarkupTool = .arrow
    @State private var color: CaptureMarkupColor = .red
    @State private var annotations: [CaptureMarkupAnnotation] = []
    @State private var draft: CaptureMarkupAnnotation?
    @State private var text = ""
    @State private var selectedID: UUID?
    @State private var movingOriginal: CaptureMarkupAnnotation?

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(CaptureMarkupTool.allCases, id: \.self) { candidate in
                    Button {
                        tool = candidate
                        if candidate != .select { selectedID = nil }
                    } label: {
                        Label(candidate.label, systemImage: candidate.symbol)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(tool == candidate ? Color.cyan.opacity(0.2) : Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tool == candidate ? .cyan : .white.opacity(0.75))
                }

                Spacer(minLength: 4)

                Button {
                    _ = annotations.popLast()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .disabled(annotations.isEmpty)
                .help("Undo")

                Button {
                    if let selectedID {
                        annotations.removeAll { $0.id == selectedID }
                        self.selectedID = nil
                    } else {
                        annotations.removeAll()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(annotations.isEmpty)
                .help(selectedID == nil ? "Clear markup" : "Delete selected markup")
            }

            GeometryReader { geometry in
                let fitted = Self.aspectFit(imageSize: image.size, in: geometry.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.35))

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    Canvas { context, size in
                        for annotation in annotations {
                            draw(annotation, in: &context, size: size)
                            if annotation.id == selectedID {
                                drawSelection(around: annotation, in: &context, size: size)
                            }
                        }
                        if let draft {
                            draw(draft, in: &context, size: size)
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                    .allowsHitTesting(false)

                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .gesture(markupGesture(in: fitted.size))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            }

            HStack(spacing: 8) {
                ForEach(CaptureMarkupColor.allCases, id: \.self) { candidate in
                    Button {
                        color = candidate
                        if let index = annotations.firstIndex(where: { $0.id == selectedID }) {
                            annotations[index].color = candidate
                        }
                    } label: {
                        Circle()
                            .fill(candidate.swiftUI)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(
                                color == candidate ? Color.cyan : Color.white.opacity(0.35),
                                lineWidth: color == candidate ? 2 : 1
                            ))
                    }
                    .buttonStyle(.plain)
                }

                if tool == .text {
                    TextField("Type text, then click the image", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                } else if tool == .select {
                    Text(selectedID == nil
                         ? "Click markup to select it, then drag to move it."
                         : "Drag the selected markup to move it.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                } else {
                    Text("Drag on the image to add a \(tool.label.lowercased()).")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.65))

                Button {
                    guard let rendered = CaptureMarkupRenderer.render(image: image, annotations: annotations) else { return }
                    onSave(rendered)
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                .disabled(annotations.isEmpty)
            }
        }
    }

    private func markupGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: tool == .text ? 0 : 1)
            .onChanged { value in
                if tool == .select {
                    moveSelection(from: value.startLocation, to: value.location, in: size)
                    return
                }
                guard tool != .text else { return }
                let start = normalized(value.startLocation, in: size)
                let current = normalized(value.location, in: size)
                switch tool {
                case .select:
                    break
                case .arrow:
                    draft = CaptureMarkupAnnotation(kind: .arrow(start, current), color: color)
                case .rectangle:
                    draft = CaptureMarkupAnnotation(kind: .rectangle(start, current), color: color)
                case .ellipse:
                    draft = CaptureMarkupAnnotation(kind: .ellipse(start, current), color: color)
                case .draw:
                    if case .stroke(let points) = draft?.kind {
                        draft?.kind = .stroke(points + [current])
                    } else {
                        draft = CaptureMarkupAnnotation(kind: .stroke([start, current]), color: color)
                    }
                case .text:
                    break
                }
            }
            .onEnded { gesture in
                if tool == .text {
                    let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    let annotation = CaptureMarkupAnnotation(
                        kind: .text(label, normalized(gesture.location, in: size)),
                        color: color
                    )
                    annotations.append(annotation)
                    selectedID = annotation.id
                    tool = .select
                    return
                }
                if tool == .select {
                    movingOriginal = nil
                    return
                }
                guard let draft else { return }
                annotations.append(draft)
                selectedID = draft.id
                self.draft = nil
                tool = .select
            }
    }

    private func moveSelection(from start: CGPoint, to current: CGPoint, in size: CGSize) {
        let normalizedStart = normalized(start, in: size)
        if movingOriginal == nil {
            guard let match = annotations.last(where: {
                CaptureMarkupInteraction.hitTest($0, at: normalizedStart)
            }) else {
                selectedID = nil
                return
            }
            selectedID = match.id
            movingOriginal = match
            color = match.color
        }
        guard let original = movingOriginal,
              let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
        let normalizedCurrent = normalized(current, in: size)
        let delta = CGPoint(
            x: normalizedCurrent.x - normalizedStart.x,
            y: normalizedCurrent.y - normalizedStart.y
        )
        annotations[index] = CaptureMarkupInteraction.translated(original, by: delta)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(size.width, 1), 0), 1),
            y: min(max(point.y / max(size.height, 1), 0), 1)
        )
    }

    private func draw(_ annotation: CaptureMarkupAnnotation, in context: inout GraphicsContext, size: CGSize) {
        CaptureMarkupDrawing.draw(annotation, in: &context, size: size)
    }

    private func drawSelection(around annotation: CaptureMarkupAnnotation, in context: inout GraphicsContext, size: CGSize) {
        let normalized = CaptureMarkupInteraction.bounds(of: annotation)
        let rect = CGRect(
            x: normalized.minX * size.width - 5,
            y: normalized.minY * size.height - 5,
            width: normalized.width * size.width + 10,
            height: normalized.height * size.height + 10
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(.cyan.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        )
    }

    static func aspectFit(imageSize: CGSize, in available: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum CaptureMarkupInteraction {
    static func hitTest(_ annotation: CaptureMarkupAnnotation, at point: CGPoint, tolerance: CGFloat = 0.025) -> Bool {
        switch annotation.kind {
        case .arrow(let start, let end):
            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance
        case .rectangle, .ellipse, .text:
            return bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .stroke(let points):
            if points.count == 1 {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance
            }
            return zip(points, points.dropFirst()).contains {
                distance(from: point, toSegmentFrom: $0.0, to: $0.1) <= tolerance
            }
        }
    }

    static func translated(_ annotation: CaptureMarkupAnnotation, by requested: CGPoint) -> CaptureMarkupAnnotation {
        let bounds = bounds(of: annotation)
        let delta = CGPoint(
            x: min(max(requested.x, -bounds.minX), 1 - bounds.maxX),
            y: min(max(requested.y, -bounds.minY), 1 - bounds.maxY)
        )
        var moved = annotation
        switch annotation.kind {
        case .arrow(let start, let end):
            moved.kind = .arrow(start + delta, end + delta)
        case .rectangle(let start, let end):
            moved.kind = .rectangle(start + delta, end + delta)
        case .ellipse(let start, let end):
            moved.kind = .ellipse(start + delta, end + delta)
        case .stroke(let points):
            moved.kind = .stroke(points.map { $0 + delta })
        case .text(let value, let location):
            moved.kind = .text(value, location + delta)
        }
        return moved
    }

    static func bounds(of annotation: CaptureMarkupAnnotation) -> CGRect {
        switch annotation.kind {
        case .arrow(let start, let end), .rectangle(let start, let end), .ellipse(let start, let end):
            return rect(start, end)
        case .stroke(let points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { bounds, point in
                bounds.union(CGRect(origin: point, size: .zero))
            }
        case .text(let value, let location):
            return CGRect(
                x: location.x,
                y: location.y,
                width: min(1 - location.x, max(0.06, CGFloat(value.count) * 0.022)),
                height: min(1 - location.y, 0.07)
            )
        }
    }

    private static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + projection * dx), point.y - (start.y + projection * dy))
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}

private enum CaptureMarkupDrawing {
    static func draw(_ annotation: CaptureMarkupAnnotation, in context: inout GraphicsContext, size: CGSize) {
        let color = annotation.color.swiftUI
        let lineWidth = max(2, min(size.width, size.height) * 0.009)
        switch annotation.kind {
        case .arrow(let start, let end):
            let a = point(start, in: size)
            let b = point(end, in: size)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(10, lineWidth * 4)
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 6),
                                     y: b.y - head * sin(angle - .pi / 6)))
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 6),
                                     y: b.y - head * sin(angle + .pi / 6)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        case .rectangle(let start, let end):
            context.stroke(Path(rect(point(start, in: size), point(end, in: size))),
                           with: .color(color), lineWidth: lineWidth)
        case .ellipse(let start, let end):
            context.stroke(Path(ellipseIn: rect(point(start, in: size), point(end, in: size))),
                           with: .color(color), lineWidth: lineWidth)
        case .stroke(let points):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: point(first, in: size))
            for value in points.dropFirst() { path.addLine(to: point(value, in: size)) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        case .text(let value, let location):
            context.draw(
                Text(value)
                    .font(.system(size: max(16, size.height * 0.045), weight: .bold))
                    .foregroundStyle(color),
                at: point(location, in: size),
                anchor: .topLeading
            )
        }
    }

    private static func point(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum CaptureMarkupRenderer {
    static func render(image: NSImage, annotations: [CaptureMarkupAnnotation]) -> NSImage? {
        var sourceRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else { return nil }
        let size = NSSize(width: source.width, height: source.height)
        guard let bitmap = NSBitmapImageRep(
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
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        graphics.imageInterpolation = .high
        NSImage(cgImage: source, size: size).draw(in: NSRect(origin: .zero, size: size))
        let lineWidth = max(3, min(size.width, size.height) * 0.009)

        for annotation in annotations {
            annotation.color.appKit.setStroke()
            annotation.color.appKit.setFill()
            switch annotation.kind {
            case .arrow(let start, let end):
                let a = outputPoint(start, size: size)
                let b = outputPoint(end, size: size)
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: a)
                path.line(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(14, lineWidth * 4)
                path.move(to: b)
                path.line(to: NSPoint(x: b.x - head * cos(angle - .pi / 6),
                                      y: b.y - head * sin(angle - .pi / 6)))
                path.move(to: b)
                path.line(to: NSPoint(x: b.x - head * cos(angle + .pi / 6),
                                      y: b.y - head * sin(angle + .pi / 6)))
                path.stroke()
            case .rectangle(let start, let end):
                let path = NSBezierPath(rect: outputRect(start, end, size: size))
                path.lineWidth = lineWidth
                path.stroke()
            case .ellipse(let start, let end):
                let path = NSBezierPath(ovalIn: outputRect(start, end, size: size))
                path.lineWidth = lineWidth
                path.stroke()
            case .stroke(let points):
                guard let first = points.first else { continue }
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: outputPoint(first, size: size))
                for point in points.dropFirst() { path.line(to: outputPoint(point, size: size)) }
                path.stroke()
            case .text(let value, let location):
                let fontSize = max(18, size.height * 0.045)
                let point = outputPoint(location, size: size)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: annotation.color.appKit,
                ]
                (value as NSString).draw(at: NSPoint(x: point.x, y: point.y - fontSize), withAttributes: attributes)
            }
        }
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }

    private static func outputPoint(_ point: CGPoint, size: NSSize) -> NSPoint {
        NSPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    private static func outputRect(_ a: CGPoint, _ b: CGPoint, size: NSSize) -> NSRect {
        let left = min(a.x, b.x) * size.width
        let right = max(a.x, b.x) * size.width
        let top = min(a.y, b.y) * size.height
        let bottom = max(a.y, b.y) * size.height
        return NSRect(x: left, y: size.height - bottom, width: right - left, height: bottom - top)
    }
}
