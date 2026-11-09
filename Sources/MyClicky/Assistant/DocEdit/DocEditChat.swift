import Combine
import Foundation
import SwiftUI

/// Drives the "Edit with DeepSeek" panel. Each message runs one agent task
/// over the project's tools, and every tool call is mirrored as a step line
/// under the assistant's answer.
@MainActor
final class DocEditChatModel: ObservableObject {
    struct StepLine: Identifiable, Equatable {
        let id: Int
        var title: String
        var status: AgentStep.Status
    }

    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        var text: String
        var steps: [StepLine]
    }

    @Published private(set) var messages: [Message]
    @Published private(set) var busy: Bool
    @Published private(set) var errorText: String?
    @Published private(set) var canRestore: Bool

    private let project: DocEditProject
    private let makeClient: () -> any AgentModelClient
    private let renderer: @Sendable (DocEditProject) async throws -> String
    private let onFilmChanged: () -> Void
    private var runningTask: Task<Void, Never>?

    init(project: DocEditProject,
         makeClient: @escaping () -> any AgentModelClient = { DeepSeekAgentClient() },
         renderer: @escaping @Sendable (DocEditProject) async throws -> String,
         onFilmChanged: @escaping () -> Void) {
        self.project = project
        self.makeClient = makeClient
        self.renderer = renderer
        self.onFilmChanged = onFilmChanged
        self.messages = []
        self.busy = false
        self.errorText = nil
        self.canRestore = project.hasBackup
    }

    /// Starts one agent task for `text`, unless it is blank or one is
    /// already running.
    func send(_ text: String) {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !busy else { return }

        let history = completedHistory()
        errorText = nil
        messages.append(Message(role: .user, text: task, steps: []))
        messages.append(Message(role: .assistant, text: "", steps: []))
        let assistantID = messages[messages.count - 1].id
        busy = true

        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let film = try self.project.describe()
                let system = DocEditToolRunner.systemPrompt + "\n\nThe film right now:\n" + film
                let loop = AgentLoop(
                    client: self.makeClient(),
                    tools: DocEditToolRunner(project: self.project, renderer: self.renderer),
                    system: system,
                    maxSteps: 12,
                    oneToolPerStep: true,
                    onStep: { [weak self] step in
                        Task { @MainActor in
                            self?.apply(step, to: assistantID)
                        }
                    }
                )
                let answer = try await loop.run(task: task, history: history)
                self.finish(assistantID: assistantID, answer: answer)
            } catch is CancellationError {
                self.stopped(assistantID: assistantID)
            } catch {
                if Task.isCancelled {
                    self.stopped(assistantID: assistantID)
                } else {
                    self.failed(assistantID: assistantID, error: error)
                }
            }
        }
    }

    /// Stops the running task; "Stopped." lands in the assistant bubble when
    /// the loop notices the cancellation.
    func cancel() {
        runningTask?.cancel()
    }

    /// Puts the film back the way it was before any edits.
    func restoreOriginal() {
        guard !busy else { return }
        do {
            try project.restoreBackup()
            canRestore = false
            messages.append(Message(role: .assistant, text: "Restored the original film.", steps: []))
            onFilmChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Task plumbing

    /// The earlier user/assistant pairs, skipping answers that never arrived.
    private func completedHistory() -> [(question: String, answer: String)] {
        var history: [(question: String, answer: String)] = []
        var index = 0
        while index + 1 < messages.count {
            let question = messages[index]
            let answer = messages[index + 1]
            if question.role == .user, answer.role == .assistant {
                let answerText = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !answerText.isEmpty {
                    history.append((question: question.text, answer: answerText))
                }
                index += 2
            } else {
                index += 1
            }
        }
        return history
    }

    private func apply(_ step: AgentStep, to assistantID: UUID) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if let stepIndex = messages[messageIndex].steps.firstIndex(where: { $0.id == step.id }) {
            messages[messageIndex].steps[stepIndex].title = step.title
            messages[messageIndex].steps[stepIndex].status = step.status
        } else {
            messages[messageIndex].steps.append(StepLine(id: step.id, title: step.title, status: step.status))
        }
    }

    private func setAssistantText(_ assistantID: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].text = text
    }

    private func finish(assistantID: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        setAssistantText(assistantID, trimmed.isEmpty ? "Done." : answer)
        busy = false
        canRestore = project.hasBackup
        runningTask = nil
    }

    private func stopped(assistantID: UUID) {
        setAssistantText(assistantID, "Stopped.")
        busy = false
        canRestore = project.hasBackup
        runningTask = nil
    }

    private func failed(assistantID: UUID, error: Error) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }),
           messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }
        errorText = error.localizedDescription
        busy = false
        canRestore = project.hasBackup
        runningTask = nil
    }
}

/// The chat panel: talk to DeepSeek about the film, watch the tool calls as
/// step lines, and restore the original film if the edits go wrong.
struct DocEditChatView: View {
    @ObservedObject var model: DocEditChatModel
    let accent: Color
    let onClose: () -> Void

    @State private var draft = ""

    private static let suggestions = [
        "What does the narrator say right now?",
        "Change the narration at 0:03 to say something shorter",
        "Remove the scene about …",
    ]

    var body: some View {
        VStack(spacing: 10) {
            header
            conversation
            if let errorText = model.errorText {
                errorLine(errorText)
            }
            composer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit with DeepSeek")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Changes the script, re-records the changed scenes and re-renders the film.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if model.canRestore && !model.busy {
                Button("Restore original") { model.restoreOriginal() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Put the film back the way it was before any edits")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        messageRow(message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .onChange(of: model.messages) { _, _ in
                scrollToLatest(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell me what to change. For example:")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    draft = suggestion
                } label: {
                    Text(suggestion)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = model.messages.last?.id else { return }
        proxy.scrollTo(id, anchor: .bottom)
    }

    private func messageRow(_ message: DocEditChatModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.role == .user {
                Text(message.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(11)
                    .background(userBubbleBackground)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13.5))
                        .lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(11)
                        .background(assistantBubbleBackground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.steps.isEmpty {
                    stepsView(message.steps)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .id(message.id)
    }

    // MARK: - Bubbles

    private var userBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(accent.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent.opacity(0.9))
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 3)
            }
    }

    private var assistantBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 3)
                    .padding(.vertical, 7)
                    .padding(.leading, 3)
            }
    }

    private func stepsView(_ steps: [DocEditChatModel.StepLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                HStack(spacing: 6) {
                    statusIcon(step.status)
                    Text(step.title)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(.leading, 6)
    }

    @ViewBuilder
    private func statusIcon(_ status: AgentStep.Status) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Error and composer

    private func errorLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.red.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Working… rendering can take several minutes")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Say what to change…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                    .onSubmit { submit() }
                sendButton
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendButton: some View {
        Button {
            if model.busy {
                model.cancel()
            } else {
                submit()
            }
        } label: {
            Image(systemName: model.busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(sendButtonTint)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.busy && trimmedDraft.isEmpty)
        .help(model.busy ? "Stop" : "Send")
    }

    private var sendButtonTint: Color {
        if model.busy { return accent }
        return trimmedDraft.isEmpty ? Color.white.opacity(0.25) : accent
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedDraft.isEmpty, !model.busy else { return }
        let text = trimmedDraft
        draft = ""
        model.send(text)
    }
}
