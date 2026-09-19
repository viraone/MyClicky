import SwiftUI
import Translation

/// An invisible view that lends the editor Apple's on-device translator.
/// `TranslationSession` only exists inside `.translationTask`, so the model
/// can't hold one; instead it bumps `translationJob` and this view runs the
/// pass, handing the session's work back as a plain "lines in, lines out"
/// closure. The system may show its own sheet the first time to download a
/// language.
@available(macOS 15, *)
struct SubtitleTranslationRunner: View {
    @ObservedObject var model: VideoEditorModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                await model.translateMissingCues { lines in
                    let requests = lines.enumerated().map {
                        TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
                    }
                    let responses = try await session.translations(from: requests)
                    var out = lines
                    for response in responses {
                        if let id = response.clientIdentifier, let index = Int(id), out.indices.contains(index) {
                            out[index] = response.targetText
                        }
                    }
                    return out
                }
            }
            .onChange(of: model.translationJob) { _, _ in
                let source = model.translationSource
                let target = model.translationTarget
                // Same pair again: invalidate so the task re-runs. New pair:
                // a fresh configuration starts a new session.
                if var existing = configuration, existing.source == source, existing.target == target {
                    existing.invalidate()
                    configuration = existing
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                }
            }
    }
}
