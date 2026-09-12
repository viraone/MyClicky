import AppKit
import XCTest
@testable import MyClicky

@MainActor
final class AssistantStateTests: XCTestCase {
    func testChangingTheLocalModelReportsTheOneLeftBehind() {
        let saved = UserDefaults.standard.string(forKey: AssistantState.codeOllamaModelKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AssistantState.codeOllamaModelKey) }
            else { UserDefaults.standard.removeObject(forKey: AssistantState.codeOllamaModelKey) }
        }
        let state = AssistantState()
        state.codeOllamaModel = "qwen3-coder:30b"   // known starting point, before we listen
        var changes: [(from: String, to: String)] = []
        state.onCodeModelChanged = { changes.append((from: $0, to: $1)) }

        state.codeOllamaModel = "qwen3-coder:30b"   // same again: nothing to let go of
        state.codeOllamaModel = "gpt-oss:20b"
        state.codeOllamaModel = "llama3.3:latest"

        XCTAssertEqual(changes.map(\.from), ["qwen3-coder:30b", "gpt-oss:20b"])
        XCTAssertEqual(changes.map(\.to), ["gpt-oss:20b", "llama3.3:latest"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: AssistantState.codeOllamaModelKey), "llama3.3:latest",
                       "the choice still persists")
    }

    func testCodeAcceptsImagesOnlyWithClaude() {
        withSavedCodeProvider {
            let state = AssistantState()
            state.codeAIProvider = .claude
            XCTAssertTrue(state.codeAcceptsImages)
            state.codeAIProvider = .ollama
            XCTAssertFalse(state.codeAcceptsImages)
            state.codeAIProvider = .claude
            XCTAssertTrue(state.codeAcceptsImages)
        }
    }

    func testSwitchingToLocalClearsImagesBeforeNotifyingAndDoesNotRestoreThem() {
        withSavedCodeProvider {
            for count in [1, 2] {
                let state = AssistantState()
                state.codeAIProvider = .claude
                state.codeImages = (0..<count).map {
                    AssistantState.AskAttachment(image: NSImage(size: .init(width: 1, height: 1)), name: "\($0).png")
                }
                let before = state.codeLog.count
                var imagesAtNotification: Int?
                state.onCodeProviderChanged = { _ in imagesAtNotification = state.codeImages.count }

                state.codeAIProvider = .ollama

                XCTAssertTrue(state.codeImages.isEmpty)
                XCTAssertEqual(imagesAtNotification, 0)
                XCTAssertEqual(state.codeLog.count, before + 1)
                XCTAssertEqual(state.codeLog.last?.kind, .status)
                XCTAssertEqual(state.codeLog.last?.text,
                               "Removed \(count) attached image\(count == 1 ? "" : "s") — the local model is text-only. Switch to Claude to attach images.")
                state.codeAIProvider = .claude
                XCTAssertTrue(state.codeImages.isEmpty)
                XCTAssertEqual(state.codeLog.count, before + 1)
                state.onCodeProviderChanged = nil
            }
        }
    }

    func testSwitchingToLocalWithoutImagesDoesNotLog() {
        withSavedCodeProvider {
            let state = AssistantState()
            state.codeAIProvider = .claude
            let before = state.codeLog.count
            state.codeAIProvider = .ollama
            XCTAssertEqual(state.codeLog.count, before)
        }
    }

    func testProjectBrowserPreservesNestedAndRootFileDrafts() {
        for path in ["tests/smoke/jobs.smoke.spec.ts", "main.swift"] {
            let state = AssistantState()
            let project = CodeProject(root: URL(fileURLWithPath: "/tmp/PeekyNavigation"),
                                      name: "PeekyNavigation", files: [.init(path: path, text: "original")],
                                      profile: nil, detectedStack: [], skippedFolders: [], skippedFiles: [], truncated: false)
            state.codeProject = project
            state.codeFocusedFile = path
            state.codeDraft = "unsaved edit"
            state.codeLSPHover = "existing hover"
            state.codeLSPCaretOffset = 4
            state.codeFindVisible = true
            state.codeFindQuery = "edit"
            state.logCode(.question, "Keep this conversation")
            var focusCalls = 0
            var documentChanges = 0
            state.onLSPFocusFile = { _, _ in focusCalls += 1 }
            state.onLSPDocumentChange = { _, _ in documentChanges += 1 }

            for _ in 0..<3 {
                state.codeViewerExpanded = true
                state.showCodeFiles()
                XCTAssertTrue(state.codeShowingFiles)
                XCTAssertTrue(state.codeViewerExpanded)
                state.showCodeFiles()
                XCTAssertTrue(state.codeShowingFiles, "root navigation is idempotent")
                XCTAssertEqual(state.codeFocusedFile, path)
                XCTAssertEqual(state.codeDraft, "unsaved edit")

                state.codeFocusedFile = path // The existing file-row action.
                XCTAssertTrue(state.codeShowingFiles, "selecting a file keeps the browser visible")
                XCTAssertEqual(state.codeDraft, "unsaved edit")

                state.toggleCodeFiles()
                XCTAssertFalse(state.codeShowingFiles)
                XCTAssertTrue(state.codeViewerExpanded)
                state.toggleCodeFiles()
                XCTAssertTrue(state.codeShowingFiles)
                XCTAssertTrue(state.codeViewerExpanded)
                XCTAssertEqual(state.codeFocusedFile, path)
                XCTAssertEqual(state.codeDraft, "unsaved edit")
            }
            XCTAssertEqual(state.codeProject, project)
            XCTAssertEqual(state.codeLog.map(\.text), ["Keep this conversation"])
            XCTAssertEqual(state.codeLSPHover, "existing hover")
            XCTAssertEqual(state.codeLSPCaretOffset, 4)
            XCTAssertTrue(state.codeFindVisible)
            XCTAssertEqual(state.codeFindQuery, "edit")
            XCTAssertEqual(focusCalls, 0)
            XCTAssertEqual(documentChanges, 0)
        }
    }

    func testOpeningAnotherFileKeepsTheProjectBrowserVisible() {
        let state = AssistantState()
        state.codeProject = CodeProject(root: URL(fileURLWithPath: "/tmp/PeekyNavigation"),
                                        name: "PeekyNavigation",
                                        files: [.init(path: "a.swift", text: "a"), .init(path: "b.swift", text: "b")],
                                        profile: nil, detectedStack: [], skippedFolders: [], skippedFiles: [], truncated: false)
        state.showCodeFiles()
        state.codeFocusedFile = "a.swift"
        XCTAssertTrue(state.codeShowingFiles)
        state.codeFocusedFile = "b.swift"
        XCTAssertTrue(state.codeShowingFiles)
        XCTAssertEqual(state.codeDraft, "b")
    }

    func testProjectDisclosureWithoutAnOpenFile() {
        let state = AssistantState()
        state.showCodeFiles()
        XCTAssertFalse(state.codeShowingFiles)
        state.codeProject = CodeProject(root: URL(fileURLWithPath: "/tmp/PeekyNavigation"),
                                        name: "PeekyNavigation", files: [.init(path: "main.swift", text: "")],
                                        profile: nil, detectedStack: [], skippedFolders: [], skippedFiles: [], truncated: false)
        state.toggleCodeFiles()
        XCTAssertTrue(state.codeShowingFiles)
        state.toggleCodeFiles()
        XCTAssertFalse(state.codeShowingFiles)
        XCTAssertNil(state.codeFocusedFile)
    }

    private func withSavedCodeProvider(_ body: () -> Void) {
        let saved = UserDefaults.standard.string(forKey: AssistantState.codeProviderKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AssistantState.codeProviderKey) }
            else { UserDefaults.standard.removeObject(forKey: AssistantState.codeProviderKey) }
        }
        body()
    }

    func testLocalModelsGetReadableNames() {
        XCTAssertEqual(AssistantState.ollamaDisplayName("qwen3-coder:30b"), "Qwen3-Coder 30B")
        XCTAssertEqual(AssistantState.ollamaDisplayName("qwen3-coder-next:latest"), "Qwen3-Coder-Next 80B")
        XCTAssertEqual(AssistantState.ollamaDisplayName("qwen3-coder-next"), "Qwen3-Coder-Next 80B")
        XCTAssertEqual(AssistantState.ollamaDisplayName("gpt-oss:20b"), "GPT-OSS 20B")
        XCTAssertEqual(AssistantState.ollamaDisplayName("llama3.3:latest"), "llama3.3", "unknown tags drop a bare :latest")
        XCTAssertEqual(AssistantState.ollamaDisplayName("qwen2.5-coder:32b"), "qwen2.5-coder:32b", "unknown variants stay as-is")
    }
}

@MainActor
final class CodeLSPToggleTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "codeLSPEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "codeLSPEnabled")
    }

    func testLSPDefaultsToEnabledAndPersistsTheToggle() {
        let state = AssistantState()
        XCTAssertTrue(state.codeLSPEnabled)

        state.codeLSPEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "codeLSPEnabled") as? Bool, false)
        XCTAssertFalse(AssistantState().codeLSPEnabled, "a fresh state should remember the choice")
    }

    func testDisabledStatusReadsAsOffWithARestartHint() {
        XCTAssertEqual(CodeLSPStatus.disabled.label, "LSP off")
        XCTAssertTrue(CodeLSPStatus.disabled.detail.contains("click to start"))
        XCTAssertNotEqual(CodeLSPStatus.disabled, .inactive)
    }
}
