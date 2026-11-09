import XCTest
@testable import MyClicky

final class DocEditProjectTests: XCTestCase {
    private var folder: URL!
    private var project: DocEditProject!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocEditProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeProject()
        project = DocEditProject(folder: folder)
    }

    override func tearDownWithError() throws {
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
        folder = nil
        project = nil
        try super.tearDownWithError()
    }

    func testFormatTime() {
        XCTAssertEqual(DocEditProject.formatTime(8.12), "0:08.1")
        XCTAssertEqual(DocEditProject.formatTime(20.5), "0:20.5")
        XCTAssertEqual(DocEditProject.formatTime(65.34), "1:05.3")
        XCTAssertEqual(DocEditProject.formatTime(35.0), "0:35.0")
        XCTAssertEqual(DocEditProject.formatTime(-3.0), "0:00.0")
    }

    func testScenesReadsFieldsAndTimes() throws {
        let filmTitle = try project.title()
        XCTAssertEqual(filmTitle, "Async in Swift")

        let scenes = try project.scenes()
        XCTAssertEqual(scenes.count, 4)
        XCTAssertEqual(scenes.map(\.id), ["title", "code1", "code2", "credits"])
        XCTAssertEqual(scenes.map(\.kind), ["title", "code", "code", "credits"])
        XCTAssertEqual(scenes[0].heading, "")
        XCTAssertEqual(scenes[1].heading, "Why async")
        XCTAssertEqual(scenes[2].heading, "Why await")
        XCTAssertEqual(scenes[3].heading, "")
        XCTAssertEqual(scenes[0].narration, "Opening.")
        XCTAssertEqual(scenes[1].narration, "First code.")
        XCTAssertEqual(scenes[2].narration, "Second code.")
        XCTAssertEqual(scenes[3].narration, "The end.")

        let start0 = try XCTUnwrap(scenes[0].start)
        let end0 = try XCTUnwrap(scenes[0].end)
        let start1 = try XCTUnwrap(scenes[1].start)
        let end1 = try XCTUnwrap(scenes[1].end)
        let end3 = try XCTUnwrap(scenes[3].end)
        XCTAssertEqual(start0, 0.0, accuracy: 0.0001)
        XCTAssertEqual(end0, 8.12, accuracy: 0.0001)
        XCTAssertEqual(start1, 8.12, accuracy: 0.0001)
        XCTAssertEqual(end1, 20.5, accuracy: 0.0001)
        XCTAssertEqual(end3, 40.0, accuracy: 0.0001)
    }

    func testDescribeUntouchedProject() throws {
        let expected = [
            "Film: \"Async in Swift\", 4 scenes, 0:40.0 long.",
            "Narrator voice: am_michael",
            "Scenes (times are where each one plays in the film right now):",
            "1. id=title kind=title 0:00.0-0:08.1",
            "   narration: \"Opening.\"",
            "2. id=code1 kind=code heading=\"Why async\" 0:08.1-0:20.5",
            "   narration: \"First code.\"",
            "3. id=code2 kind=code heading=\"Why await\" 0:20.5-0:35.0",
            "   narration: \"Second code.\"",
            "4. id=credits kind=credits 0:35.0-0:40.0",
            "   narration: \"The end.\"",
        ].joined(separator: "\n")

        let text = try project.describe()
        XCTAssertEqual(text, expected)
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    func testDescribeAfterEditShowsPendingLine() throws {
        try project.setNarration(sceneID: "code1", text: "New words.")
        let text = try project.describe()
        XCTAssertTrue(text.hasPrefix("Film: \"Async in Swift\", 4 scenes, 0:40.0 long."))
        XCTAssertTrue(text.contains("   narration: \"New words.\""))
        XCTAssertTrue(text.hasSuffix("\nEdited but not rendered yet: code1."))
    }

    func testSetNarrationChangesOnlyThatSceneAndBacksUpOnce() throws {
        let scriptURL = folder.appendingPathComponent("script.json")
        let backupURL = folder.appendingPathComponent(DocEditProject.backupFolderName)
        let originalData = try Data(contentsOf: scriptURL)

        try project.setNarration(sceneID: "code1", text: "  Better words.  ")

        XCTAssertTrue(project.hasBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("timeline.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("documentary.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("audio").path))
        let backedUpData = try Data(contentsOf: backupURL.appendingPathComponent("script.json"))
        XCTAssertEqual(backedUpData, originalData)

        let root = try jsonObject(at: scriptURL)
        let scenes = try XCTUnwrap(root["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes.count, 4)
        XCTAssertEqual(scenes[0]["narration"] as? String, "Opening.")
        XCTAssertEqual(scenes[1]["narration"] as? String, "Better words.")
        XCTAssertEqual(scenes[1]["heading"] as? String, "Why async")
        XCTAssertEqual(scenes[2]["narration"] as? String, "Second code.")
        let lines = try XCTUnwrap(scenes[1]["lines"] as? [Any]).compactMap { $0 as? String }
        XCTAssertEqual(lines, ["a", "b"])
        let illustration = try XCTUnwrap(scenes[1]["illustration"] as? [String: Any])
        XCTAssertEqual(illustration["caption"] as? String, "diagram")
        XCTAssertEqual(project.pendingSceneIDs(), ["code1"])

        try project.setNarration(sceneID: "code2", text: "Last words.")
        let backedUpAgain = try Data(contentsOf: backupURL.appendingPathComponent("script.json"))
        XCTAssertEqual(backedUpAgain, originalData)
        XCTAssertEqual(project.pendingSceneIDs(), ["code1", "code2"])
    }

    func testEmptyNarrationIsRefusedWithoutCreatingBackup() throws {
        XCTAssertThrowsError(try project.setNarration(sceneID: "code1", text: "   \n ")) { error in
            self.assertRefused(error, "Narration cannot be empty.")
        }
        XCTAssertFalse(project.hasBackup)
        let backupURL = folder.appendingPathComponent(DocEditProject.backupFolderName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("script.json").path))
        let scenes = try project.scenes()
        XCTAssertEqual(scenes[1].narration, "First code.")
    }

    func testSetHeadingLeavesPendingEmpty() throws {
        try project.setHeading(sceneID: "code2", text: "  Why await matters  ")
        let scenes = try project.scenes()
        XCTAssertEqual(scenes[2].heading, "Why await matters")
        XCTAssertEqual(project.pendingSceneIDs(), [])
        XCTAssertTrue(project.hasBackup)
    }

    func testDeleteSceneRemovesAndMarksPending() throws {
        try project.deleteScene(sceneID: "code2")
        let scenes = try project.scenes()
        XCTAssertEqual(scenes.map(\.id), ["title", "code1", "credits"])
        XCTAssertEqual(project.pendingSceneIDs(), ["code2"])
        XCTAssertTrue(project.hasBackup)
    }

    func testCreditsSceneCannotBeDeleted() throws {
        XCTAssertThrowsError(try project.deleteScene(sceneID: "credits")) { error in
            self.assertRefused(error, "Cannot delete the credits scene.")
        }
        let scenes = try project.scenes()
        XCTAssertEqual(scenes.count, 4)
        XCTAssertFalse(project.hasBackup)
    }

    func testDeletingDownToTwoScenesThenRefused() throws {
        try project.deleteScene(sceneID: "code1")
        let afterFirst = try project.scenes().map(\.id)
        XCTAssertEqual(afterFirst, ["title", "code2", "credits"])

        try project.deleteScene(sceneID: "code2")
        let afterSecond = try project.scenes().map(\.id)
        XCTAssertEqual(afterSecond, ["title", "credits"])
        XCTAssertEqual(project.pendingSceneIDs(), ["code1", "code2"])

        XCTAssertThrowsError(try project.deleteScene(sceneID: "title")) { error in
            self.assertRefused(error, "A film needs at least 2 scenes.")
        }
        let afterRefusal = try project.scenes().map(\.id)
        XCTAssertEqual(afterRefusal, ["title", "credits"])
    }

    func testUnknownSceneID() throws {
        XCTAssertThrowsError(try project.setNarration(sceneID: "nope", text: "Words.")) { error in
            self.assertUnknownScene(error, id: "nope")
        }
        XCTAssertThrowsError(try project.setHeading(sceneID: "nope", text: "Words.")) { error in
            self.assertUnknownScene(error, id: "nope")
        }
        XCTAssertThrowsError(try project.deleteScene(sceneID: "nope")) { error in
            self.assertUnknownScene(error, id: "nope")
        }
        XCTAssertFalse(project.hasBackup)
        XCTAssertEqual(project.pendingSceneIDs(), [])
    }

    func testPrepareForRenderDeletesPendingWavsAndClearsPending() throws {
        try project.setNarration(sceneID: "code1", text: "First again.")
        try project.setNarration(sceneID: "code2", text: "Second again.")
        let audio = folder.appendingPathComponent("audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("code1.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("code2.wav").path))

        let pending = try project.prepareForRender()
        XCTAssertEqual(pending, ["code1", "code2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.appendingPathComponent("code1.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.appendingPathComponent("code2.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("title.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("credits.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("durations.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("voice.json").path))
        XCTAssertEqual(project.pendingSceneIDs(), [])
    }

    func testRestoreBackupBringsBackFilesAndRemovesBackup() throws {
        let fm = FileManager.default
        let audio = folder.appendingPathComponent("audio")
        let movie = folder.appendingPathComponent("documentary.mp4")
        let backup = folder.appendingPathComponent(DocEditProject.backupFolderName)

        try project.setNarration(sceneID: "code1", text: "Changed.")
        XCTAssertTrue(project.hasBackup)

        try fm.removeItem(at: audio.appendingPathComponent("code1.wav"))
        try fm.removeItem(at: movie)
        XCTAssertFalse(fm.fileExists(atPath: audio.appendingPathComponent("code1.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: movie.path))

        try project.restoreBackup()

        let scenes = try project.scenes()
        XCTAssertEqual(scenes[1].narration, "First code.")
        XCTAssertTrue(fm.fileExists(atPath: audio.appendingPathComponent("code1.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: movie.path))
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
        XCTAssertFalse(project.hasBackup)
        XCTAssertEqual(project.pendingSceneIDs(), [])
    }

    func testRestoreWithoutBackupIsRefused() {
        XCTAssertThrowsError(try project.restoreBackup()) { error in
            self.assertRefused(error, "There is nothing to restore.")
        }
        XCTAssertFalse(project.hasBackup)
    }

    func testVoiceReadsVoiceJSON() throws {
        XCTAssertEqual(project.voice(), "am_michael")
        let voiceURL = folder.appendingPathComponent("audio").appendingPathComponent("voice.json")
        try FileManager.default.removeItem(at: voiceURL)
        XCTAssertNil(project.voice())
    }

    // MARK: - Helpers

    private func makeProject() throws {
        let fm = FileManager.default
        let audio = folder.appendingPathComponent("audio", isDirectory: true)
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)

        let script: [String: Any] = [
            "title": "Async in Swift",
            "subtitle": "A short code documentary",
            "source": "Sources/MyClicky/Assistant/Agent/AgentLoop.swift",
            "scenes": [
                ["id": "title", "kind": "title", "narration": "Opening."],
                ["id": "code1", "kind": "code", "heading": "Why async", "narration": "First code.",
                 "lines": ["a", "b"], "illustration": ["caption": "diagram", "color": "blue"]],
                ["id": "code2", "kind": "code", "heading": "Why await", "narration": "Second code."],
                ["id": "credits", "kind": "credits", "narration": "The end."],
            ],
        ]
        try writeJSON(script, to: folder.appendingPathComponent("script.json"))

        let timeline: [String: Any] = [
            "scenes": [
                ["id": "title", "start": 0.0, "end": 8.12],
                ["id": "code1", "start": 8.12, "end": 20.5],
                ["id": "code2", "start": 20.5, "end": 35.0],
                ["id": "credits", "start": 35.0, "end": 40.0],
            ],
        ]
        try writeJSON(timeline, to: folder.appendingPathComponent("timeline.json"))

        for id in ["title", "code1", "code2", "credits"] {
            try Data("wav-\(id)".utf8).write(to: audio.appendingPathComponent("\(id).wav"))
        }
        let durations: [String: Double] = ["title": 8.12, "code1": 12.38, "code2": 14.5, "credits": 5.0]
        try writeJSON(durations, to: audio.appendingPathComponent("durations.json"))
        let voice: [String: Any] = ["engine": "kokoro", "voice": "am_michael", "speed": 0.95]
        try writeJSON(voice, to: audio.appendingPathComponent("voice.json"))
        try Data("mp4".utf8).write(to: folder.appendingPathComponent("documentary.mp4"))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func assertRefused(_ error: Error, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let docError = error as? DocEditError, case .refused(let reason) = docError else {
            XCTFail("Expected a refusal, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(reason, message, file: file, line: line)
    }

    private func assertUnknownScene(_ error: Error, id: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let docError = error as? DocEditError, case .unknownScene(let sceneID) = docError else {
            XCTFail("Expected an unknown scene, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(sceneID, id, file: file, line: line)
    }
}
