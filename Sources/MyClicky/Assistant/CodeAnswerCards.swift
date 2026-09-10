import AppKit
import SwiftUI

/// Each answer owns its per-segment toggle state; indices cannot leak to another answer.
struct CodeAnswerCards: View {
    @ObservedObject var state: AssistantState
    let text: String
    @State private var codeRawBlocks: Set<Int> = []

    var body: some View {
        let segments = CodeAnswerSegment.parse(text)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .prose(let prose):
                    Text(state.codeLinkedProse(prose))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let loc = AssistantState.jumpLocation(from: url) { state.jump(to: loc) }
                            return .handled
                        })
                case .code(let language, let code, let tagged):
                    let previous: String? = index > 0 ? {
                        if case .code(_, let earlier, _) = segments[index - 1] { return earlier }
                        if index > 1, case .code(_, let earlier, _) = segments[index - 2],
                           case .prose = segments[index - 1] { return earlier }
                        return nil
                    }() : nil
                    codeBlockCard(index: index, language: language, code: code, previous: previous, tagged: tagged)
                }
            }
        }
    }

    private func codeBlockCard(index: Int, language: String, code: String, previous candidate: String?, tagged: String?) -> some View {
        // The block before this one is the "find" half of a change only if
        // it's actually in the file — otherwise it's an unrelated snippet.
        let previous: String? = candidate.flatMap { earlier in
            state.codePaths.contains { state.codeBlockIsAlreadyInFile(earlier, path: $0) } ? earlier : nil
        }
        let location = state.codeLocate(code: code, find: previous, tagged: tagged)
        let target: String? = location?.path ?? state.codeFocusedFile
        let alreadyThere = target.map { state.codeBlockIsAlreadyInFile(code, path: $0) } ?? false
        let live = target.flatMap { state.codeLiveText(of: $0) }
        let rewrite = live.map { CodeBlockApplier.apply(code, replacing: nil, in: $0).1 == .rewroteFile } ?? false
        let old = !alreadyThere && target != nil ? (previous ?? (rewrite ? live : nil)) : nil
        let changes = old.map { LineDiff.diff($0, code) }
        return VStack(alignment: .leading, spacing: 0) {
            codeBlockHeader(language: language, code: code, previous: previous, location: location, target: target,
                            index: index, changes: changes)
            if previous != nil, let changes, !codeRawBlocks.contains(index) {
                codeDiffBody(changes)
            } else {
                Text(code)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func codeBlockHeader(language: String, code: String, previous: String?,
                                 location: CodeBlockLocator.Location?, target: String?,
                                 index: Int, changes: [LineDiff.Line]?) -> some View {
        let targetName: String? = target.map { ($0 as NSString).lastPathComponent }
        let alreadyThere: Bool = target.map { state.codeBlockIsAlreadyInFile(code, path: $0) } ?? false
        return HStack(spacing: 8) {
            Text(language.isEmpty ? "code" : language)
                .foregroundStyle(.white.opacity(0.4))
            if let location, let name = targetName {
                let label: String = location.line.map { "\(name):\($0)" } ?? name
                Button {
                    state.jump(to: location)
                } label: {
                    Label(label, systemImage: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AssistantPhase.working.color)
                .help(location.line == nil ? "Open \(location.path)" : "Open \(location.path) at line \(location.line ?? 0)")
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy this code")
            if let target, let name = targetName {
                if alreadyThere {
                    // A quote of what's there now — the "find" half of a
                    // change, or just a pointer to where something lives.
                    Label("already in \(name)", systemImage: "checkmark")
                        .foregroundStyle(.white.opacity(0.4))
                        .help("This is what the file says now — nothing to apply")
                } else {
                    if let changes {
                        codeDiffSummary(changes)
                        if previous != nil {
                            Button(codeRawBlocks.contains(index) ? "code" : "diff") {
                                if !codeRawBlocks.insert(index).inserted { codeRawBlocks.remove(index) }
                            }
                            .buttonStyle(.plain)
                            .help("Toggle diff / replacement code")
                        }
                    }
                    Button {
                        state.onApplyCodeBlock?(code, previous, target)
                    } label: {
                        Label("Apply to \(name)", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AssistantPhase.done.color)
                    .help(previous == nil
                          ? "Put this code into \(target)"
                          : "Replace the code shown before it with this, in \(target)")
                }
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05))
    }

    private func codeDiffSummary(_ lines: [LineDiff.Line]) -> some View {
        let count = LineDiff.summary(lines)
        return HStack(spacing: 5) {
            Text("+\(count.added)").foregroundStyle(AssistantPhase.done.color)
            Text("−\(count.removed)").foregroundStyle(Color.red)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func codeDiffBody(_ lines: [LineDiff.Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(LineDiff.rows(lines).enumerated()), id: \.offset) { _, row in
                codeDiffRow(row)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func codeDiffRow(_ row: LineDiff.Row) -> some View {
        switch row {
        case .unchanged(let count):
            Text("··· \(count) unchanged lines ···")
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
        case .line(let line):
            HStack(alignment: .top, spacing: 8) {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                    .frame(width: 10)
                Text(line.text.isEmpty ? " " : line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white.opacity(line.kind == .same ? 0.55 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(line.kind == .removed ? Color.red.opacity(0.18)
                        : line.kind == .added ? AssistantPhase.done.color.opacity(0.18) : Color.clear)
        }
    }
}
