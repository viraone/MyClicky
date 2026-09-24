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

enum CaptureMarkupDragTarget: Equatable {
    case move
    case arrowStart
    case arrowEnd
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
    @State private var dragTarget: CaptureMarkupDragTarget?
    @State private var background: CaptureBackgroundStyle = .lastUsed()
    // Open the section when a saved backdrop is in play, so it's obvious where it comes from.
    @State private var showsBackgroundControls = CaptureBackgroundStyle.lastUsed().changesOutput

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(CaptureMarkupTool.allCases, id: \.self) { candidate in
                    Button {
                        choose(candidate)
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

                // Icon-only like Undo and Trash: the tool row already fills the
                // narrowest panel, and a text label would truncate the tools.
                Button {
                    showsBackgroundControls.toggle()
                } label: {
                    Image(systemName: "rectangle.inset.filled")
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsBackgroundControls || background.changesOutput
                                 ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.foreground))
                .help("Background: padding, backdrop, shadow and rounded corners")

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

            if showsBackgroundControls {
                backgroundControls
            }

            GeometryReader { geometry in
                let layout = CaptureBackgroundLayout(imageSize: pixelSize, style: background)
                    .fitted(toWidth: geometry.size.width)
                // Annotations and gestures live in the capture's own frame, so
                // normalized coordinates ignore the padding entirely.
                let canvasSize = layout.screenshotFrame.size
                ScrollView(.vertical) {
                    // Padding is equal on every side, so centring the capture
                    // layers in the composition lands them on `screenshotFrame`.
                    ZStack {
                        CaptureBackgroundPreview(image: image, style: background, layout: layout)
                            .equatable()

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
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .highPriorityGesture(markupGesture(in: canvasSize))
                    }
                    .frame(width: layout.compositionSize.width, height: layout.compositionSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.cyan.opacity(0.45), lineWidth: 1))
                }
                .background(Color.black.opacity(0.18))
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
                         ? "Choose a shape, then drag exactly where it should go."
                         : selectedArrowHint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                } else {
                    Text(tool == .arrow
                         ? "Drag from the arrow's exact start point to its tip."
                         : "Drag on the image to add a \(tool.label.lowercased()).")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.65))

                Button {
                    guard let rendered = CaptureMarkupRenderer.render(
                        image: image,
                        annotations: annotations,
                        background: background
                    ) else { return }
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
                .disabled(annotations.isEmpty && !background.changesOutput)
            }
        }
        .onChange(of: background) { _, style in
            style.saveAsLastUsed()
        }
    }

    /// The capture's pixel size, which is what padding is measured against.
    /// Retina captures have twice as many pixels as points, and the export
    /// works in pixels, so the preview must too or the padding would look
    /// twice as wide on screen as it comes out.
    private var pixelSize: CGSize {
        CaptureMarkupRenderer.pixelSize(of: image)
    }

    /// Three short rows so the section still fits the half-width panel:
    /// presets and fill type, the fill's own colours, then geometry.
    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(CaptureBackgroundStyle.presets) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        CaptureBackgroundSwatch(
                            fill: preset.style.fill,
                            isSelected: background.fill == preset.style.fill
                        )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }

                Divider()
                    .frame(height: 16)

                Picker("Fill", selection: fillKind) {
                    ForEach(CaptureBackgroundStyle.Fill.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 190)

                Spacer(minLength: 0)
            }

            switch background.fill {
            case .none:
                EmptyView()
            case .solid(let color):
                HStack(spacing: 8) {
                    controlLabel("Color")
                    ColorPicker("Color", selection: colorBinding(color) { .solid($0) })
                        .labelsHidden()
                        .help("Backdrop color")
                    Spacer(minLength: 0)
                }
            case .gradient(let start, let end, let angle):
                HStack(spacing: 8) {
                    controlLabel("From")
                    ColorPicker("Start", selection: colorBinding(start) {
                        .gradient(start: $0, end: end, angle: angle)
                    })
                    .labelsHidden()
                    .help("Gradient start color")
                    controlLabel("To")
                    ColorPicker("End", selection: colorBinding(end) {
                        .gradient(start: start, end: $0, angle: angle)
                    })
                    .labelsHidden()
                    .help("Gradient end color")
                    labeledSlider("Angle", value: gradientAngle, in: 0...360, step: 15, width: 110)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 12) {
                labeledSlider("Padding", value: $background.padding,
                              in: CaptureBackgroundStyle.paddingRange, step: 1)
                labeledSlider("Corners", value: $background.cornerRadius,
                              in: CaptureBackgroundStyle.cornerRadiusRange, step: 1)
                Toggle("Shadow", isOn: $background.shadow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>,
        step: CGFloat,
        width: CGFloat? = nil
    ) -> some View {
        HStack(spacing: 6) {
            controlLabel(title)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .frame(width: width)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, alignment: .trailing)
        }
    }

    /// From a plain capture a preset brings its whole look. Once padding and
    /// corners have been tuned, presets only swap the backdrop so that work sticks.
    private func apply(_ preset: CaptureBackgroundPreset) {
        if preset.style == .plain || !background.changesOutput {
            background = preset.style
        } else {
            background.fill = preset.style.fill
        }
    }

    private var fillKind: Binding<CaptureBackgroundStyle.Fill.Kind> {
        Binding(
            get: { background.fill.kind },
            set: { kind in
                let fill = background.fill.converted(to: kind)
                if kind != .none, !background.changesOutput {
                    // A fill behind a capture with no padding is invisible; give it the default look.
                    background = CaptureBackgroundStyle(fill: fill)
                } else {
                    background.fill = fill
                }
            }
        )
    }

    private var gradientAngle: Binding<CGFloat> {
        Binding(
            get: {
                guard case .gradient(_, _, let angle) = background.fill else { return 0 }
                return CGFloat(angle)
            },
            set: { angle in
                guard case .gradient(let start, let end, _) = background.fill else { return }
                background.fill = .gradient(start: start, end: end, angle: Double(angle))
            }
        )
    }

    private func colorBinding(
        _ current: CaptureBackgroundColor,
        _ makeFill: @escaping (CaptureBackgroundColor) -> CaptureBackgroundStyle.Fill
    ) -> Binding<Color> {
        Binding(
            get: { current.swiftUI },
            set: { background.fill = makeFill(CaptureBackgroundColor($0)) }
        )
    }

    private func choose(_ candidate: CaptureMarkupTool) {
        tool = candidate
        if candidate != .select { selectedID = nil }
        movingOriginal = nil
        dragTarget = nil
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
                    dragTarget = nil
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
            guard let match = CaptureMarkupInteraction.annotationToMove(
                in: annotations,
                selectedID: selectedID,
                at: normalizedStart
            ) else {
                selectedID = nil
                return
            }
            selectedID = match.id
            movingOriginal = match
            dragTarget = CaptureMarkupInteraction.dragTarget(
                for: match,
                at: normalizedStart,
                canvasSize: size
            )
            color = match.color
        }
        guard let original = movingOriginal,
              let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
        let normalizedCurrent = normalized(current, in: size)
        annotations[index] = CaptureMarkupInteraction.adjusted(
            original,
            target: dragTarget ?? .move,
            dragStart: normalizedStart,
            current: normalizedCurrent
        )
    }

    private var selectedArrowHint: String {
        guard let selectedID,
              let annotation = annotations.first(where: { $0.id == selectedID }),
              case .arrow = annotation.kind else {
            return "Drag anywhere on the image to move the selected markup."
        }
        return "Drag either round handle to turn or resize the arrow; drag elsewhere to move it."
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
        if case .arrow(let start, let end) = annotation.kind {
            for point in [start, end] {
                let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                let handle = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: handle), with: .color(.cyan))
                context.stroke(Path(ellipseIn: handle), with: .color(.white), lineWidth: 1.5)
            }
        }
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

    static func widthFit(imageSize: CGSize, width: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, width > 0 else { return .zero }
        return CGSize(width: width, height: width * imageSize.height / imageSize.width)
    }
}

enum CaptureMarkupInteraction {
    static func dragTarget(
        for annotation: CaptureMarkupAnnotation,
        at point: CGPoint,
        canvasSize: CGSize,
        handleRadius: CGFloat = 18
    ) -> CaptureMarkupDragTarget {
        guard case .arrow(let start, let end) = annotation.kind else { return .move }
        let startDistance = pixelDistance(point, start, canvasSize: canvasSize)
        let endDistance = pixelDistance(point, end, canvasSize: canvasSize)
        if min(startDistance, endDistance) > handleRadius { return .move }
        return startDistance <= endDistance ? .arrowStart : .arrowEnd
    }

    static func adjusted(
        _ annotation: CaptureMarkupAnnotation,
        target: CaptureMarkupDragTarget,
        dragStart: CGPoint,
        current: CGPoint
    ) -> CaptureMarkupAnnotation {
        var adjusted = annotation
        switch (target, annotation.kind) {
        case (.arrowStart, .arrow(_, let end)):
            adjusted.kind = .arrow(clamped(current), end)
        case (.arrowEnd, .arrow(let start, _)):
            adjusted.kind = .arrow(start, clamped(current))
        default:
            adjusted = translated(
                annotation,
                by: CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
            )
        }
        return adjusted
    }

    static func annotationToMove(
        in annotations: [CaptureMarkupAnnotation],
        selectedID: UUID?,
        at point: CGPoint
    ) -> CaptureMarkupAnnotation? {
        if let selectedID,
           let selected = annotations.first(where: { $0.id == selectedID }) {
            return selected
        }
        return annotations.last(where: { hitTest($0, at: point) })
    }

    static func hitTest(_ annotation: CaptureMarkupAnnotation, at point: CGPoint, tolerance: CGFloat = 0.025) -> Bool {
        if bounds(of: annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
            return true
        }
        switch annotation.kind {
        case .arrow(let start, let end):
            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance
        case .rectangle, .ellipse, .text:
            return false
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

    private static func pixelDistance(_ a: CGPoint, _ b: CGPoint, canvasSize: CGSize) -> CGFloat {
        hypot((a.x - b.x) * canvasSize.width, (a.y - b.y) * canvasSize.height)
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
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

/// The backdrop, shadow and rounded capture, drawn in the same order as the
/// export so the preview is the export scaled down. Kept as its own equatable
/// view so dragging annotations doesn't redraw the full-size capture.
private struct CaptureBackgroundPreview: View, Equatable {
    let image: NSImage
    let style: CaptureBackgroundStyle
    let layout: CaptureMarkupPreviewLayout

    static func == (lhs: CaptureBackgroundPreview, rhs: CaptureBackgroundPreview) -> Bool {
        lhs.image === rhs.image && lhs.style == rhs.style && lhs.layout == rhs.layout
    }

    var body: some View {
        Canvas { context, size in
            let frame = layout.screenshotFrame
            let scale = layout.scale
            let bounds = CGRect(origin: .zero, size: size)

            switch style.fill {
            case .none:
                break
            case .solid(let color):
                context.fill(Path(bounds), with: .color(color.swiftUI))
            case .gradient(let start, let end, let angle):
                let line = CaptureBackgroundStyle.gradientLine(angle: angle, in: bounds)
                context.fill(Path(bounds), with: .linearGradient(
                    Gradient(colors: [start.swiftUI, end.swiftUI]),
                    startPoint: line.start,
                    endPoint: line.end
                ))
            }

            let shape = Path(roundedRect: frame, cornerRadius: style.cornerRadius * scale, style: .circular)
            context.drawLayer { layer in
                if style.castsShadow {
                    layer.addFilter(.shadow(
                        color: .black.opacity(style.shadowOpacity),
                        radius: style.shadowRadius * scale,
                        x: style.shadowOffset.width * scale,
                        y: style.shadowOffset.height * scale
                    ))
                }
                // A nested layer makes the shadow follow the clipped shape as a whole.
                layer.drawLayer { capture in
                    if style.cornerRadius > 0 {
                        capture.clip(to: shape)
                    }
                    capture.draw(Image(nsImage: image), in: frame)
                }
            }
        }
        .frame(width: layout.compositionSize.width, height: layout.compositionSize.height)
    }
}

private struct CaptureBackgroundSwatch: View {
    let fill: CaptureBackgroundStyle.Fill
    let isSelected: Bool

    var body: some View {
        Group {
            switch fill {
            case .none:
                Image(systemName: "circle.slash")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            case .solid(let color):
                Circle().fill(color.swiftUI)
            case .gradient(let start, let end, let angle):
                let points = CaptureBackgroundStyle.gradientUnitPoints(angle: angle)
                Circle().fill(LinearGradient(
                    colors: [start.swiftUI, end.swiftUI],
                    startPoint: points.start,
                    endPoint: points.end
                ))
            }
        }
        .frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(
            isSelected ? Color.cyan : Color.white.opacity(0.35),
            lineWidth: isSelected ? 2 : 1
        ))
    }
}

enum CaptureMarkupRenderer {
    /// The capture's pixel dimensions, falling back to its point size for
    /// representations without fixed pixels.
    static func pixelSize(of image: NSImage) -> CGSize {
        let candidates = image.representations
            .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? image.size
    }

    /// Draws the backdrop, then the shadow, then the rounded capture, then the
    /// annotations shifted by the padding. With `.plain` this is the exact call
    /// sequence the renderer made before backgrounds existed.
    static func render(
        image: NSImage,
        annotations: [CaptureMarkupAnnotation],
        background: CaptureBackgroundStyle = .plain
    ) -> NSImage? {
        var sourceRect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil) else { return nil }
        let style = background.clamped
        let imageSize = NSSize(width: source.width, height: source.height)
        let layout = CaptureBackgroundLayout(imageSize: imageSize, style: style)
        let size = layout.outputSize
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
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
        // AppKit's origin is bottom-left, but equal padding on every side means
        // the capture's rect is the same numbers in either orientation.
        let capture = NSRect(x: layout.padding, y: layout.padding, width: imageSize.width, height: imageSize.height)
        drawFill(style.fill, in: NSRect(origin: .zero, size: size))
        drawCapture(NSImage(cgImage: source, size: imageSize), in: capture, style: style, padding: layout.padding, context: graphics)
        let lineWidth = max(3, min(imageSize.width, imageSize.height) * 0.009)

        for annotation in annotations {
            annotation.color.appKit.setStroke()
            annotation.color.appKit.setFill()
            switch annotation.kind {
            case .arrow(let start, let end):
                let a = outputPoint(start, in: capture)
                let b = outputPoint(end, in: capture)
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
                let path = NSBezierPath(rect: outputRect(start, end, in: capture))
                path.lineWidth = lineWidth
                path.stroke()
            case .ellipse(let start, let end):
                let path = NSBezierPath(ovalIn: outputRect(start, end, in: capture))
                path.lineWidth = lineWidth
                path.stroke()
            case .stroke(let points):
                guard let first = points.first else { continue }
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: outputPoint(first, in: capture))
                for point in points.dropFirst() { path.line(to: outputPoint(point, in: capture)) }
                path.stroke()
            case .text(let value, let location):
                let fontSize = max(18, capture.height * 0.045)
                let point = outputPoint(location, in: capture)
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

    private static func drawFill(_ fill: CaptureBackgroundStyle.Fill, in rect: NSRect) {
        switch fill {
        case .none:
            return
        case .solid(let color):
            color.appKit.setFill()
            rect.fill()
        case .gradient(let start, let end, let angle):
            // The line is computed top-left like the preview; flip y for AppKit.
            let line = CaptureBackgroundStyle.gradientLine(angle: angle, in: rect)
            NSGradient(starting: start.appKit, ending: end.appKit)?.draw(
                from: NSPoint(x: line.start.x, y: rect.height - line.start.y),
                to: NSPoint(x: line.end.x, y: rect.height - line.end.y),
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
            )
        }
    }

    private static func drawCapture(
        _ capture: NSImage,
        in rect: NSRect,
        style: CaptureBackgroundStyle,
        padding: CGFloat,
        context: NSGraphicsContext
    ) {
        guard padding > 0 || style.cornerRadius > 0 else {
            // Nothing to decorate: the pre-background draw, byte for byte.
            capture.draw(in: rect)
            return
        }
        let cg = context.cgContext
        cg.saveGState()
        if style.castsShadow {
            // Drawn inside a transparency layer so the shadow follows the
            // rounded, clipped capture rather than the clip cutting it off.
            cg.setShadow(
                offset: CGSize(width: style.shadowOffset.width, height: -style.shadowOffset.height),
                blur: style.shadowRadius,
                color: NSColor.black.withAlphaComponent(style.shadowOpacity).cgColor
            )
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if style.cornerRadius > 0 {
            NSBezierPath(roundedRect: rect, xRadius: style.cornerRadius, yRadius: style.cornerRadius).addClip()
        }
        capture.draw(in: rect)
        if style.castsShadow {
            cg.endTransparencyLayer()
        }
        cg.restoreGState()
    }

    private static func outputPoint(_ point: CGPoint, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + (1 - point.y) * rect.height)
    }

    private static func outputRect(_ a: CGPoint, _ b: CGPoint, in rect: NSRect) -> NSRect {
        let left = rect.minX + min(a.x, b.x) * rect.width
        let right = rect.minX + max(a.x, b.x) * rect.width
        let top = min(a.y, b.y) * rect.height
        let bottom = max(a.y, b.y) * rect.height
        return NSRect(x: left, y: rect.minY + rect.height - bottom, width: right - left, height: bottom - top)
    }
}
