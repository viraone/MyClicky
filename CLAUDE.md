# Local workers (added 2026-11-03)

Routine typing goes to the local Qwen worker (the `qwen-gateway` MCP tools, configured in `.gateway.toml`) or to
DeepSeek (`/pass-to-deepseek`). Claude writes the spec and reviews the diff. The rules are the ones in
`~/Developer/beezer/CLAUDE.md` ("Qwen Gateway — operating rules"); this is what differs here.

## Who gets what
- **Qwen** (free, local): one or two files under ~30 KB with a pattern to copy, such as a test in
  `Tests/MyClickyTests`, a small helper, or a copy change. It writes whole files back, so never give it a large file,
  even though `.gateway.toml` allows up to 200 KB: `ClickyRemote/Sources/NumpadView.swift` (about 160 KB, 3,500 lines),
  `Sources/MyClicky/Assistant/AssistantController.swift`, `AssistantPanel.swift`, `CodeDocumentaryTab.swift`.
- **DeepSeek** (`~/.claude/skills/pass-to-deepseek/run.sh`): routine work bigger than two files, in a large file, or
  that needs reading around the code. Its ask mode
  (`~/.claude/skills/pass-to-deepseek/ask.sh ~/Developer/MyClicky1 "<question>"`, read-only) answers "where is X / how
  does Y work" so Claude does not read source to write a spec.
  DeepSeek's session cannot run `xcodebuild` or `swift` (refused by its permissions, seen 2026-11-03), so its work is
  not compiled until Claude runs the build in review.
- **Claude**: the spec, the review, anything ambiguous or design-heavy, anything both workers failed.
- **Claude or DeepSeek, never Qwen:** anything under `ClickyRemote/` (see the gate below).
- After each delegated task, say in one line whether it passed first time, after a retry, or failed.

## What this repo expects (put it in every spec)
- Two apps: the Mac app (`Sources/MyClicky`, Swift package, macOS 14) and the iPhone remote (`ClickyRemote/`, its own
  Xcode project generated from `project.yml`). A new source file in the remote may need `xcodegen` to be picked up.
- The gate is `swift build --build-system native --disable-sandbox`, then the same with `swift test`. Keep
  `--build-system native`: the default build fails on SwiftTerm's Metal shader.
- **The gate does not compile `ClickyRemote/`.** A green gate says nothing about the remote. Check it with:
  `xcodebuild -project ClickyRemote/ClickyRemote.xcodeproj -scheme ClickyRemote -destination 'generic/platform=iOS Simulator' build`
- Tests live in `Tests/MyClickyTests/<Name>Tests.swift` and import the code with `@testable import MyClicky`.
- See the Mac app with `scripts/build-app.sh`, which quits the old copy and opens the new one.
- This repo is public. Never commit or list for a worker: keys, tokens, device IDs, or `ClickyLogs/data.js`.
