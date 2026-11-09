import Foundation

/// The script-editing tools for a Peeky Code Doc. Every call goes through the
/// project's own file operations; the runner only turns tool calls into
/// project calls and remembers whether a render is still owed.
final class DocEditToolRunner: AgentToolRunning, @unchecked Sendable {
    /// What the model is told before it sees the current scene list.
    static let systemPrompt = """
    You edit a narrated mini documentary (a Peeky Code Doc) that the user is watching. The film is a list of scenes. Each scene has an id, sometimes a heading, and narration that a narrator voice speaks over the picture. The scene list at the end of this message shows where each scene plays in the film right now.

    Rules:
    - To change what the narrator says, call set_narration for that scene. Use the times the user gives to find the scene; the times in the list are in the film, in minutes:seconds.
    - Quote the old narration and the new narration back to the user. Keep the new narration about as long as the old one unless the user asks otherwise, because a scene lasts as long as its narration.
    - Make every script edit first, then call render once. Rendering re-records only the changed scenes and rebuilds the film, which takes several minutes. Tell the user that in one sentence before you call render.
    - Make one tool call per step. After a tool answers, read its result before the next step. Never repeat a call that already worked.
    - Change only what was asked. If the request could mean two scenes, ask one short question instead of editing.
    - You cannot see or hear the film. Only the scene list tells you what is said and shown.
    - Never say something was done unless the tool answered ok. If a tool fails, say what went wrong in plain words.
    - The user can restore the original film with a button, so do not ask permission for edits they asked for.
    - Answer briefly and plainly.
    """

    private let project: DocEditProject
    private let renderer: @Sendable (DocEditProject) async throws -> String

    /// True once a script edit succeeded and no render has finished since.
    private var dirty = false

    init(project: DocEditProject,
         renderer: @escaping @Sendable (DocEditProject) async throws -> String) {
        self.project = project
        self.renderer = renderer
    }

    var specs: [[String: Any]] {
        [
            Self.tool(name: "get_script",
                      description: "Returns the film's scenes with their ids, headings, narration and where each plays. Use it to read the current state.",
                      properties: [:],
                      requiredFields: []),
            Self.tool(name: "set_narration",
                      description: "Changes what the narrator says in one scene. The scene is re-recorded when you call render.",
                      properties: [
                        "scene_id": Self.stringProperty("The id of the scene to change."),
                        "text": Self.stringProperty("The new narration for the scene."),
                      ],
                      requiredFields: ["scene_id", "text"]),
            Self.tool(name: "set_heading",
                      description: "Changes the on-screen heading of one scene.",
                      properties: [
                        "scene_id": Self.stringProperty("The id of the scene to change."),
                        "text": Self.stringProperty("The new heading for the scene."),
                      ],
                      requiredFields: ["scene_id", "text"]),
            Self.tool(name: "delete_scene",
                      description: "Deletes one scene. The title-less credits scene and the last two scenes cannot be deleted.",
                      properties: [
                        "scene_id": Self.stringProperty("The id of the scene to delete."),
                      ],
                      requiredFields: ["scene_id"]),
            Self.tool(name: "render",
                      description: "Re-records the changed scenes and rebuilds the film. Takes several minutes. Call it once, after all edits.",
                      properties: [:],
                      requiredFields: []),
        ]
    }

    func run(name: String, input: [String: Any]) async -> AgentToolOutcome {
        switch name {
        case "get_script":
            return readScript()
        case "set_narration":
            return changeNarration(input: input)
        case "set_heading":
            return changeHeading(input: input)
        case "delete_scene":
            return deleteScene(input: input)
        case "render":
            return await renderFilm()
        default:
            return AgentToolOutcome(text: "Unknown tool: \(name)",
                                    isError: true,
                                    summary: "Unknown tool")
        }
    }

    // MARK: - Tools

    private func readScript() -> AgentToolOutcome {
        do {
            return AgentToolOutcome(text: try project.describe(), summary: "Read the script")
        } catch {
            return AgentToolOutcome(text: error.localizedDescription,
                                    isError: true,
                                    summary: "Could not read the script")
        }
    }

    private func changeNarration(input: [String: Any]) -> AgentToolOutcome {
        guard let request = sceneAndText(from: input) else {
            return badRequest("set_narration needs scene_id and text.")
        }
        do {
            try project.setNarration(sceneID: request.sceneID, text: request.text)
            dirty = true
            let text = "Narration of \"\(request.sceneID)\" is now: \"\(request.text)\". "
                + pendingNote()
                + " Call render when all edits are done."
            return AgentToolOutcome(text: text,
                                    summary: "Changed the narration of \(request.sceneID)")
        } catch {
            return AgentToolOutcome(text: error.localizedDescription,
                                    isError: true,
                                    summary: "Could not change the narration")
        }
    }

    private func changeHeading(input: [String: Any]) -> AgentToolOutcome {
        guard let request = sceneAndText(from: input) else {
            return badRequest("set_heading needs scene_id and text.")
        }
        do {
            try project.setHeading(sceneID: request.sceneID, text: request.text)
            dirty = true
            let text = "Heading of \"\(request.sceneID)\" is now: \"\(request.text)\". "
                + pendingNote()
                + " Call render when all edits are done."
            return AgentToolOutcome(text: text,
                                    summary: "Changed the heading of \(request.sceneID)")
        } catch {
            return AgentToolOutcome(text: error.localizedDescription,
                                    isError: true,
                                    summary: "Could not change the heading")
        }
    }

    private func deleteScene(input: [String: Any]) -> AgentToolOutcome {
        guard let rawID = input["scene_id"] as? String else {
            return badRequest("delete_scene needs scene_id.")
        }
        let sceneID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sceneID.isEmpty else {
            return badRequest("delete_scene needs scene_id.")
        }
        do {
            try project.deleteScene(sceneID: sceneID)
            dirty = true
            var text = "Deleted scene \"\(sceneID)\". "
                + pendingNote()
                + " Call render when all edits are done."
            if let script = try? project.describe() {
                text += "\n\n" + script
            } else {
                text += "\n\nThe scene was deleted, but I couldn't read the new script."
            }
            return AgentToolOutcome(text: text, summary: "Deleted scene \(sceneID)")
        } catch {
            return AgentToolOutcome(text: error.localizedDescription,
                                    isError: true,
                                    summary: "Could not delete the scene")
        }
    }

    private func renderFilm() async -> AgentToolOutcome {
        guard dirty else {
            return AgentToolOutcome(text: "Nothing to render: no scene has changed since the last render.",
                                    isError: true,
                                    summary: "Nothing to render")
        }
        do {
            _ = try project.prepareForRender()
            let result = try await renderer(project)
            dirty = false
            return AgentToolOutcome(text: result, summary: "Re-rendered the film")
        } catch {
            return AgentToolOutcome(text: "Rendering failed: \(error.localizedDescription)",
                                    isError: true,
                                    summary: "Rendering failed")
        }
    }

    // MARK: - Input and notes

    private func sceneAndText(from input: [String: Any]) -> (sceneID: String, text: String)? {
        guard let rawID = input["scene_id"] as? String,
              let rawText = input["text"] as? String else { return nil }
        let sceneID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sceneID.isEmpty, !text.isEmpty else { return nil }
        return (sceneID, text)
    }

    private func badRequest(_ text: String) -> AgentToolOutcome {
        AgentToolOutcome(text: text, isError: true, summary: "Bad request")
    }

    private func pendingNote() -> String {
        let ids = project.pendingSceneIDs().joined(separator: ", ")
        if ids.isEmpty { return "Edited but not rendered yet." }
        return "Edited but not rendered yet: \(ids)."
    }

    // MARK: - Tool specs

    private static func tool(name: String,
                             description: String,
                             properties: [String: Any],
                             requiredFields: [String]) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": requiredFields,
        ]
        return [
            "name": name,
            "description": description,
            "input_schema": schema,
        ]
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }
}
