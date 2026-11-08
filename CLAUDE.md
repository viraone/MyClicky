# Workers (added 2026-11-03, moved to the Mac Studio 2026-11-06)

Routine typing goes to the gateway worker (the `qwen-gateway` MCP tools, configured in `.gateway.toml`), which is the
Mac Studio. Cloud DeepSeek (`/pass-to-deepseek`) is a fallback that needs a stated reason. Claude writes the spec and
reviews the diff, and does not read project source itself. The rules are the ones in `~/Developer/beezer/CLAUDE.md`
("Qwen Gateway — operating rules") and in `~/Downloads/myclicky-studio-briefing.md`; this is what differs here.

## Before delegating
- Read the stack status (`bash ~/.claude/skills/stack/stack.sh status`). The `Studio model:` line is the one that
  matters; `Qwen server: retired` is expected. If the Studio is OFF, say so and use `/pass-to-deepseek` meanwhile.
  Never edit `.gateway.toml` to switch models, and never try to start Qwen on this MacBook.

## Who gets what

**The Mac Studio is the default worker. The cloud needs a reason.** Viradeth paid about $10,000 for it and wants it
used as much as possible; Claude's tokens and cloud DeepSeek (paid from his DeepSeek key) are the billed things. The
worker the gateway tools call "qwen" is DeepSeek V4-Flash on the Studio (key read from a private file, never printed);
the MacBook Qwen is retired. It sees only the files you list and reads about 400 tokens a second, so each 60 KB adds
about 45 s before it writes.

Follow in order, every task:
1. Read the stack status. Studio OFF: say so, use `/pass-to-deepseek` meanwhile, never edit `.gateway.toml`.
2. Reading code to write a spec: `studio_ask.py` first when you know the files
   (`cd ~/qwen-gateway && .venv/bin/python studio_ask.py --project /Users/viradeth/Developer/MyClicky1 -q "<question>" <file> ...`,
   `--think` for logic). Cloud ask mode (`~/.claude/skills/pass-to-deepseek/ask.sh ~/Developer/MyClicky1 "<question>"`)
   only when you do not know where something lives, or the file is over 200 KB.
3. Editing: the gateway worker first, up to about six files and 150 KB listed in total, with a clear spec and an
   existing pattern to copy (it edits with SEARCH/REPLACE, so a long file is fine). Do not send work to the cloud
   because it touches more than two files. The 150 KB is a budget, not a wall; the 200 KB `max_file_bytes` in
   `.gateway.toml` is the hard limit, and the gateway skips any file over it.
4. Tiny edit (3 lines or fewer, in lines already quoted this session, no new logic): do it with Edit, run the gate,
   say "did it myself, N lines".
5. Same task failed twice on the Studio: cloud DeepSeek, with the Studio's failing gate output in the brief. Fix by
   hand only if cloud DeepSeek fails too.
6. After every delegated task, one line: passed first time / after a retry / failed, and how long it took.
7. At the end of any session where code was written, give a count of tasks done by the Studio, by cloud DeepSeek and
   by Claude, and one honest sentence for each task that was not the Studio.

**When the cloud may go first** (say which, and why, in the recap; never go there silently): a file over 200 KB (name
it and its size, and propose splitting it), more than about six files or 150 KB, a task that runs commands, or one
that needs reading around the code. Cloud DeepSeek's session cannot run `xcodebuild` or `swift` (refused by its
permissions, seen 2026-11-03), so its work is not compiled until Claude runs the build in review.

**The big files here** (bytes, measured 2026-11-08): `AssistantPanel.swift` 287,357 and `AssistantController.swift`
274,449 are over the 200 KB cap, so the Studio cannot be given them until they are split (a separate task Viradeth
approves). `ClickyRemote/Sources/NumpadView.swift` 174,060 is under the cap. `CodeDocumentaryTab.swift` 122,634 is
under the budget.

**`ClickyRemote/` (Viradeth said yes 2026-11-08, replacing the old "never the Studio" rule).** The Studio may do
small, fully specified edits there. The gateway gate only builds and tests the main Swift package, so a gateway
"pass" says nothing about the remote: treat every `ClickyRemote/` result as UNVERIFIED until Claude has run
`xcodebuild -project ClickyRemote/ClickyRemote.xcodeproj -scheme ClickyRemote -destination 'generic/platform=iOS Simulator' build`,
before saying "accepted", and the recap says that it was run and what it showed. Additive and exact: named files,
exact signatures and strings, "send only the edits needed, then stop"; no cleanups, no deletions. If `xcodebuild`
fails, the Studio gets ONE retry with the exact compiler errors pasted into the spec; if that fails too, escalate to
cloud DeepSeek with those errors.

**`NumpadView.swift` (174 KB; Viradeth said yes 2026-11-08).** List it alone, plus only a test file if the task needs
one. Reading it takes about two minutes and the gateway allows 240 s for a first attempt; an attempt over 240 s gets
no retry, so write a tight spec with exact strings and signatures: one shot. If the first attempt fails after 240 s,
go to cloud DeepSeek with the failing output and tell Viradeth. Use `studio_ask.py` first only when the exact lines to
change are unknown, and quote every line you need in one question (it reads the same file again).

**Specs for the Studio** (it executes a fully specified edit well and dithers on judgment):
- Files, exact signatures and strings, edge cases, what the tests assert, what NOT to change. End every spec with:
  "Do not restructure. Send only the edits needed, then stop."
- Additive beats subtractive. Removals: quote the exact lines with `studio_ask.py` first, then "delete exactly these
  lines". Never ask it to shrink a file or to "clean up whatever becomes unused".
- Compute every expected test value by hand, and say: "if a test and the code disagree, fix the TEST, never the
  component."
- A rewrite over about 12,000 characters in one block trips the runaway guard: write a new file and change one line,
  or dictate 10-15 small exact edits.
- Thinking is off by default; `thinking="on"` only for real logic (dates, algorithms, expected values), never for a
  no-op or a deletion. Attempts are capped at one retry, none if the first took over 240 s.
- Never list `.env*`, secrets, `.claude/` or build output, and never list a file only "as a pattern" when the spec
  already contains the pattern.

**Reviewing:** read the diff, `gate_output` and `added_context`, not the files. Check `git status` after any error or
timeout (the worker writes to the working tree before you approve; a failed task is undone by the gateway, key
`undone`). A call over about 50 s returns a job id: read it with `task_result`. Anything people see (the panel,
windows, copy): rebuild with `/rebuild-and-reopen-app MyClicky1`, look at it, and say what you saw, or "not looked
at". The gateway code only reaches a session after Cmd+Q and reopening the Claude app.

- **Claude**: the spec, the review, tiny edits, anything ambiguous or design-heavy, anything both workers failed.

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
