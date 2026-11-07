# Workers (added 2026-11-03, moved to the Mac Studio 2026-11-06)

Routine typing goes to the gateway worker (the `qwen-gateway` MCP tools, configured in `.gateway.toml`) or to
DeepSeek cloud (`/pass-to-deepseek`). Claude writes the spec and reviews the diff, and does not read project source
itself. The rules are the ones in `~/Developer/beezer/CLAUDE.md` ("Qwen Gateway — operating rules"); this is what
differs here.

## Before delegating
- Read the stack status (`bash ~/.claude/skills/stack/stack.sh status`). The `Studio model:` line is the one that
  matters; `Qwen server: retired` is expected. If the Studio is OFF, say so and use `/pass-to-deepseek` meanwhile.
  Never edit `.gateway.toml` to switch models, and never try to start Qwen on this MacBook.

## Who gets what
- **The gateway worker** (free; DeepSeek V4-Flash on the Mac Studio, key read from a private file, never printed):
  one or two files with a pattern to copy, such as a test in `Tests/MyClickyTests`, a small helper, or a copy change.
  It sees only the files you list and reads about 400 tokens a second, so list only what the task needs: each 60 KB
  adds about 45 s before it writes. The big files cost the most: `ClickyRemote/Sources/NumpadView.swift` (about
  160 KB), `Sources/MyClicky/Assistant/AssistantController.swift`, `AssistantPanel.swift`, `CodeDocumentaryTab.swift`.
  The first attempt runs with thinking off; a retry after a failed gate runs with it on. The MCP call gives up after
  60 s but the gateway keeps working: watch `~/qwen-gateway/gateway.log` for "delegate done", then check
  `git status` and the diff.
- **DeepSeek cloud** (`~/.claude/skills/pass-to-deepseek/run.sh`): routine work bigger than two files or that needs
  reading around the code. Its ask mode
  (`~/.claude/skills/pass-to-deepseek/ask.sh ~/Developer/MyClicky1 "<question>"`, read-only) answers "where is X / how
  does Y work" so Claude does not read source to write a spec.
  DeepSeek's session cannot run `xcodebuild` or `swift` (refused by its permissions, seen 2026-11-03), so its work is
  not compiled until Claude runs the build in review.
- **Claude**: the spec, the review, anything ambiguous or design-heavy, anything both workers failed.
- **Claude or DeepSeek cloud, never the gateway worker:** anything under `ClickyRemote/`, because the gateway's gate
  does not compile it (see below).
- After each delegated task, say in one line whether it passed first time, after a retry, or failed, and how long it
  took.

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
