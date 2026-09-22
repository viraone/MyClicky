# MyClicky

A small, native macOS quick-capture utility with a built-in AI screen assistant.

## Capture (Control–Option–X)

Press **Control–Option–X** anywhere,
drag out a region of the screen like Jing or the built-in Cmd–Shift–4 tool, and
release. MyClicky crops exactly that region and silently saves it as a PNG to
`~/Desktop/VIRADETH_RESUME/` with a timestamped filename — no save dialog, no
naming prompt. Grab a screenshot and drop it straight into a chat (Claude,
ChatGPT, etc.) via the file-upload picker.

Press **Escape**, or release without dragging, to cancel a capture.

## Assistant (hold Option–Command–C)

**Hold** Option–Command–C, speak your question, release to submit. A non-activating
panel appears with a status dot (cyan idle → red listening → yellow thinking →
green answering). Your voice is transcribed on-device (Apple Speech), the
screen under your cursor is captured, and both are sent to Claude in one
request. The answer is spoken aloud and shown in the panel. You can also type
a question in the panel's text field instead of speaking. Press Escape to
dismiss the panel.

Expanded cards and the strip follow normal macOS window stacking: selecting
another window in Mission Control or switching apps can cover Peeky, even if
that app was already active underneath it. Clicking Peeky, using its shortcut,
or sending an explicit show command from the phone brings it forward without
pinning it above subsequent selections. Selecting Peeky itself in Mission
Control also brings the visible card forward at normal level; it remains
non-activating for hotkey/phone-driven display while you type in another app.
The corner dot and Video tab
intentionally stay above other apps. Open/save pickers keep Peeky visible
during selection, then restore the current tab's normal stacking behavior.
Finder folder drags still work on a visible Peeky drop target and do not
explicitly send it to the back; if Finder overlaps it, arrange the windows so
part of Peeky remains visible before dragging.

For troubleshooting selection, the optional `peekyWindowSelectionDiagnostics`
Boolean default logs app activation, reopen, key-window callbacks, background
mouse events, and raise/lower decisions with millisecond timestamps. Messages
are public in Console under subsystem `com.local.MyClicky`, category
`WindowSelection`; they contain window classes, IDs, geometry, and guard state,
not window titles or document content. It is off by default.

The assistant isn't limited to what's on screen — depending on the question
and context, it swaps the screenshot for a more accurate source:

- **Editor-aware answers**: if Xcode, VS Code, Cursor, Android Studio, a
  JetBrains IDE, Sublime Text, or Zed is frontmost, the actual focused file
  text is read via the Accessibility API and given to Claude instead of
  relying on pixels.
- **Google Drive-aware answers**: if a Google Drive file is open in the
  active browser tab (Chrome, Safari, Arc, Edge, or Brave), the full document
  text is fetched via the Drive API so answers cover the whole file, not just
  the visible part.
- **Gmail-aware answers**: questions about "my inbox" or "my email" (that
  aren't about a specific email already on screen) are answered from a live
  digest of your recent Gmail messages.

### Click it for me

Say something like "click the save button," or "click it" to reuse the last
thing the assistant highlighted. Claude locates the element and returns its
on-screen bounding box, a highlight ring appears over the target, and a
confirmation panel asks before anything happens — confirm and MyClicky moves
the mouse and clicks it for you.

### Move a Drive file to the trash

With a Google Drive file or folder open in your browser, say "move this to
the trash" / "delete this file." MyClicky reads the active tab's URL, looks
up the file via the Drive API, and asks for confirmation before moving it to
the trash (restorable for 30 days from Drive).

### Storage cleanup (⌥⌘D Drive, ⌥⌘G Gmail)

Two hold-to-open windows for clearing out Google account storage:

- **⌥⌘D — Drive Cleanup**: scans every file you own, flags likely junk
  (empty docs, large stale files, near-duplicates) with Claude, and shows a
  review table you tick and send to Drive's trash (restorable for 30 days).
  The window header shows a live quota meter — usage against the 15 GB free
  tier, a projected "after this cleanup" total that updates as you tick rows,
  and how much is sitting in Drive's trash. If there's anything in the trash,
  an **Empty Trash** button permanently deletes it after a confirmation that
  spells out it can't be undone.
- **⌥⌘G — Gmail Cleanup**: finds messages over 10 MB (largest first, one row
  per thread), with a "Select all over 25 MB" shortcut. Selected threads move
  to Gmail's trash (restorable for 30 days) the same way Drive cleanup does.
  An **Empty Gmail Trash & Spam** button is also available, gated behind the
  same kind of permanent-delete confirmation. This feature needs no Anthropic
  key — message size is the only signal, no Claude review involved.

Google Photos isn't covered by either window: the Photos API doesn't let a
third-party app list or delete media it didn't create, so there's no way to
build an equivalent cleanup flow for it.

### One-time setup

Store your Anthropic API key in the macOS Keychain (never written to disk in
plaintext):

```bash
security add-generic-password -s MyClicky -a anthropic -w YOUR_API_KEY
```

For Gmail/Drive features, also store a Google OAuth client ID and secret
(from a Google Cloud project with the Gmail and Drive APIs enabled, configured
as a Desktop app OAuth client):

```bash
security add-generic-password -s MyClicky -a google-client-id -w YOUR_CLIENT_ID
security add-generic-password -s MyClicky -a google-client-secret -w YOUR_CLIENT_SECRET
```

The first Gmail/Drive request opens your browser for Google's consent screen
(PKCE + loopback redirect); the refresh token is then stored in the Keychain,
so you won't be asked again unless the app requests new scopes.

On first use, allow **Microphone** and **Speech Recognition** for MyClicky in
System Settings → Privacy & Security. Reading the active browser tab (for
Drive detection) requires the **Automation** permission for MyClicky, prompted
the first time it's needed.

## Run

```bash
./scripts/build-app.sh
open .build/MyClicky.app
```

On first use, allow **Screen Recording** in System Settings for MyClicky.

## Dictate (hold Option–Command–V)

Speak → text is cleaned up by Claude and copied to the clipboard. Shown in the
panel's **Dictate** tab. The panel has seven tabs: Ask, Capture + Dictate, Talk,
Peeky Code, Terminal, Peeky Code Doc, Ext (extensions).

## Peeky Code (questions about a project)

Drop a project folder — Swift, Python, HTML/CSS, JavaScript, Java, anything
text — onto the **Peeky Code** tab (or use **+ → Project folder or files…**).
Peeky reads every source file, skipping `.git`, build output, `node_modules`,
`*.xcassets`, `*.xcodeproj`, lock files, binaries and anything over 200 KB,
and shows the size (`23 files · ≈38K tokens`). Then ask: "what does this app
do?", "find the bug in the tab bar", "add a dark-mode toggle". Answers name
real files and show the exact code to change. Follow-ups build on the
conversation (⌘K clears it; the project stays).

The whole project rides along with every question as one `cache_control:
ephemeral` block, so Anthropic serves it from its prompt cache for ~5 minutes
(refreshed on each use) at a tenth of the input price. The project card
shows the effect after each question — `38K tokens from cache (≈10% price)`.
Editing files? **+ → Re-read from disk** picks up the changes (one full-price
question re-primes the cache). Projects over ~170K tokens are cut off with a
warning; drop a subfolder instead. `.env`, keys and certificates are never
bundled.

A project can add `.peeky/project-profile.md` with maintainer-authored guidance
for Peeky Code. Peeky loads it separately from source, detects the actual stack
from project files and dependencies, and includes both ahead of the cached
project block. The project card shows the active profile and detected tools;
clicking the profile badge prepares a grounded **SDET Review** that separates
implemented capabilities from planned ones and cites exact project files.

For a loaded Git repository, the compact **GitHub** card shows the validated
`origin`, current branch, clean/dirty state, staged/unstaged/untracked counts,
and upstream ahead/behind counts. Expand it to refresh that state, browse local
and remote branches, and switch safely when the worktree is clean. Peeky never
forces a checkout, discards changes, or silently stashes; it explains when
switching is blocked.

If the [GitHub CLI](https://cli.github.com/) is installed, the same card shows
its authentication state and active account, plus recent open issues and pull
requests for a GitHub `origin`; click an item to open it in the browser. Use
**Sign in in browser** to run `gh auth login --web`. Peeky delegates credentials
to `gh` and never asks for, stores, or logs a GitHub token. Missing CLI,
signed-out, non-GitHub remote, empty-list, and network/error states are shown
directly in the card.

TypeScript projects also start a project-scoped language server. The editor
shows live error/warning underlines and exposes hover information and
go-to-definition beside the **TypeScript LSP** status badge. Peeky prefers a
project-local or installed `typescript-language-server`; when neither exists,
the first TypeScript project load fetches the pinned v4 server and TypeScript 5
through npm's cache. Click the badge to switch the server off — the project and
open file stay loaded for Q&A while the server and its node workers (≈300 MB)
exit; click again to bring it back. The choice is remembered across launches.

The provider menu beside Peeky Code's question box switches between Claude and
a local Ollama model. Local mode starts Ollama when needed, defaults to
`qwen3-coder:30b` (the **Fast** choice), downloads a missing model once, and
sends project context only to `127.0.0.1`; it has no per-message API charge.
The context window is sized to the project in steps from 8K up to the model's
limit. Very large focused files are sent as a line-numbered beginning/end
excerpt, keeping routine requests at 32K or less instead of paying the latency
of a 64K or 128K cache. The project slice, focused file and unsaved edits all
travel in the system message, so Ollama can reuse its cached prefix from one
question to the next; Peeky warms that cache in the background as soon as a
project loads or a file is focused, so the first question pays only for its
answer (a 14K-token project reads in 0.1 s warm versus 11 s cold). Each answer
ends with a timing line — `read 14K tokens in 0.1 s (cached) · wrote 312 tokens
in 4.3 s` — so a slow reply is easy to diagnose. Once the prompt is cached the
answer's length is the whole wait (about 60 tokens a second), so the local
system prompt asks for brief prose — overviews in a handful of lines, code only
when you ask for a change — rather than capping output tokens, which would
truncate a two-block code edit. Only one local model is
resident at a time: Peeky keeps the active model warm for 30 minutes, starts
Ollama with a one-model limit, and picking a different model in the menu
unloads the one you left.
Attached images remain a Claude-only feature: in Local mode the + image item is disabled, dropped or pasted images are refused with a HUD message, and Peeky Captures go to the Capture tab. Switching to Local removes any images already attached; switch back to Claude to attach again.

Click the project card to browse its files and click one to preview it
(the caret on the preview folds it away); questions are then about that
file. The preview is editable: type and it saves to disk about a second
later, so an editor open on the same folder (VS Code, Xcode) picks the change
up on its own. **⌘F** opens a find bar (⌘G / ⇧⌘G next and previous match,
⌥⌘F find-and-replace, Esc closes it), like VS Code's. Put the caret next to
a `{`, `(` or `[` and its partner is outlined; double-click a bracket to
select the whole block. A line-number gutter follows hard lines through wrapping,
and a faint band highlights the caret’s line when no text is selected. Edits don't touch the cached project block — the changed
file goes along with the next question as a short addendum (pennies) rather
than re-priming the cache; ↻ re-reads everything when you want a fresh
snapshot. Code blocks in answers have **Copy** and **Apply to <file>**
buttons; when Claude gives a "current code" block followed by a
"replacement" block, Apply swaps the first for the second in the file
you're viewing (or rewrites the file when the block is a whole-file
rewrite). When an answer gives only the replacement — one complete
function, type, or method with no "current code" quote, which local models
do often — Apply finds that definition by name in the file, matches its
braces, and swaps it in place, re-indenting a flush-left method to fit.
It copies the block to the clipboard instead when there's no single
obvious spot (the name is defined twice, the block is more than one
definition, or there's no `{…}` body to match). Cards
that change code show a red/green diff of what Apply will do, with a
`+N −M` count next to the button (toggle back to the raw replacement with
the `diff`/`code` link); ⌘Z undoes an Apply in one step once it's landed.
Each block's header also says where it goes — `app.js:412`, worked out
locally from the fence's file name and the "current code" block, no Claude
call — and clicking that opens the file at those lines. **Apply** targets
that file whether or not it's the one open, then lands you on the change.
Backticked names in the prose (`initializeApp()`, `style.css`) that exist
in the project are links to where they're defined.

**▶ Run** appears on the project card when the folder holds an
`.xcodeproj` or `.xcworkspace`. It runs `xcodebuild` for the iOS Simulator
(a booted iPhone if there is one, else the newest plain iPhone), then
`simctl` boot / install / launch — Xcode's ⌘R without Xcode, all local and
free. The full output streams into the Terminal tab; under the card you see
just "Building… 23 s" → "✓ Build succeeded · launched on iPhone 17", or the
compiler's errors as rows. Click a row: the file opens at that line and
the question box is pre-filled with "Build error at File.swift:42: … Fix
it." — you press ↩ (that's the only Claude call), **Apply**, ▶ **Run**
again.
### Terminal

The **Terminal** tab is a real shell (your login shell, via SwiftTerm)
running inside Peeky, started in the folder you dropped on Peeky Code — so
after Peeky applies a change, `git diff`, `git commit`, `git push` or
`npm start` are one tab away, without leaving the panel. ↻ restarts it in
the current project. It's entirely local: nothing typed there goes to
Claude, and it costs nothing to use. The terminal takes keyboard focus when
selected: **⌘V** pastes, **⌘C** copies selected text, and **⌘K** clears.

**+ → Images for the question…** (or drop image files, or just **⌘V** a
picture off the clipboard — take a Peeky Capture, switch to the Code tab,
paste) attaches
screenshots or mockups by name — they go with every question until removed.
The card's **Cost** pill is a running estimate of what code questions have
spent, from the token counts each answer reports at Sonnet list prices;
the Claude console has the actual bill.

### Extensions

The **Ext** tab lets you extend Peeky Code without rebuilding it. An
extension is a folder with a `manifest.json` and a few scripts (shell,
AppleScript or JXA) that can contribute **languages** (highlighting for new
file types), **code themes**, **formatters** and **linters** (a Format /
Lint row appears under the open file, with findings underlined), and
**actions** — reusable verbs that join Peeky Actions, so "say hi to Vira"
can plan an extension's `say_hello` step, and the phone can fire it directly
with `EXT say_hello`. Extensions live in
`~/Library/Application Support/MyClicky/Extensions/`; install one by dropping
its folder on the tab, pasting a git URL, or picking it from the built-in
**Marketplace**, which lists a JSON catalog from
`viraone/peeky-extensions`. Toggle, reveal or trash any extension from the
same card. The manifest format, script environment and catalog schema are in
[`docs/extensions.md`](docs/extensions.md); a runnable sample is in
[`examples/extensions/hello-peeky/`](examples/extensions/hello-peeky/).

### Peeky Code Doc

The **Peeky Code Doc** tab turns one code file into a 2–4 minute narrated, animated
mini-documentary — the "explain it to me like a Netflix doc" way of reading
code. Drop a file (or paste its path in the box), pick a voice and quality,
press **Make documentary**. Claude writes a scene-by-scene script (title,
code walkthroughs with a highlight sweeping the lines, a worked example,
takeaways, credits) and picks a themed illustration for each code scene —
a pipeline of steps, before/after bars, a list narrowing under a search, two
collaborators, a checklist, or a callout. Everything after the script is
local: [Kokoro](https://github.com/hexgrad/kokoro) synthesizes the narration
and [Manim](https://www.manim.community) renders the film to
`~/code-documentary/projects/<file>-<stamp>/documentary.mp4`. The film plays right inside the tab (with rewind, play/pause and skip controls); recent films
are listed on the tab.

**Or a .txt file.** Below the code drop zone is a second one for written text —
an essay, notes, an explainer (`.txt`, `.text`, `.md`). Same pipeline, same
voice and quality pickers, but the script writer is briefed to explain a
document rather than a program: the passages appear on screen word-wrapped
without line numbers while the narrator unpacks what they mean. Dropping or
typing a path to a `.txt` anywhere on the tab lands in this section
automatically; the code drop zone itself is unchanged.

**Ask about this moment.** While a film is up, Peeky Ask is about the frame you're
on. Press **Ask** (⌘/), the mic, or type in the box — the film pauses, the
status line reads `Ask about 2:14 · The helper`, and Peeky answers from the exact
code on screen (the pipeline writes a `timeline.json` so a timestamp maps back
to the chapter, its lines and narration). The answer is spoken and shown under
the film with the lines it's about lit up, and it says plainly when it's
inferring rather than reading the code. Follow-ups: **Show me** (the same
answer as an animated step walkthrough), **Go deeper** (hands the moment to the
full Peeky Ask tab; the film stays parked), **Ask another**, and **Resume
documentary**, which continues from the same timestamp. Suggested questions for
the current chapter appear as chips.

The Peeky Remote's **PEEKY DOC** cartridge is the same session on the phone:
its **Ask Peeky** button pauses the Mac and records on the phone, the answer
and the Show me / Go deeper / Resume controls appear there too, and the
transport (restart, ±10s, play/pause, stop, scrubber) drives the film. With
nothing playing it lists recent films to start with one tap. Phone answer
read-out is **off by default**. Turn on **Read answers aloud** in the PEEKY DOC
cartridge when wanted; the Mac renders the answer with the documentary's
saved narrator voice and sends that audio to the phone instead of using
iOS's robotic system voice.

One-time setup (Python 3.12 + Homebrew):

```sh
tools/code-documentary/setup.sh          # creates ~/code-documentary with a .venv
```

The pipeline is plain Python in [`tools/code-documentary/`](tools/code-documentary/)
and runs by hand too: write a `script.json` in a folder and run
`.venv/bin/python make_doc.py <folder>`. To keep it somewhere else,
`defaults write MyClicky documentaryPipelineDir /path`.

## Peeky Remote (iOS app)

`ClickyRemote/` is a companion iPhone numpad app (open `ClickyRemote.xcodeproj`
in Xcode, run on the phone with ⌘R after any change). It finds the Mac via
Bonjour (`_clicky._tcp`) and sends newline-terminated text commands
(`RemoteControlService`). Pad: PEEKY = show/hide the Mac panel; COLLAPSE =
toggle its thin status bar; ASK = record a question on the phone and send it
(answered like ⌥⌘C); DICTATE = clean-up to the Mac clipboard; CAPTURE = region
grab; TALK = "do it" action mode. The **PEEKY CODE** mode opens Peeky Code on
the Mac and remaps DICTATE to **TERMINAL** (open the integrated terminal) and
TALK to **ENTER** (send one Return keystroke to the focused Mac control).
Tapping **PEEKY** in the phone's top mode bar restores the normal controls.
The Mac also accepts `TAB EXTENSIONS` and `EXT <verb>[\tkey=value…]` to run
an installed extension action; it replies `EXT_STATUS OK|FAIL\t<detail>`.

## ClickyLogs (weekly dashboard)

Every ask/dictate/capture/click is logged (with the site you used Peeky on)
to `~/Library/Application Support/MyClicky/ClickyLogs/*.jsonl` by
`Assistant/ActivityLog`, plus a once-a-minute frontmost-app sample.
The dashboard lives at
`~/Library/Application Support/MyClicky/ClickyLogsSite/index.html`
(bookmark it); a LaunchAgent (`com.myclicky.clickylogs`) regenerates
`data.js` every 5 minutes. Source is in `ClickyLogs/`; after editing it run
`./scripts/clickylogs.sh` to reinstall and open it. Data never leaves the Mac.
Daily log files older than 30 days are deleted automatically (the dashboard
only ever shows the trailing 7 days).

## Architecture

- `CaptureController`: hotkey → selection → capture → save orchestration
- `HotkeyMonitor`: global/local Control–Option–X key-down monitoring
- `SelectionOverlayController` / `SelectionOverlayView` / `SelectionWindow`: the
  full-screen drag-to-select overlay with live width × height readout
- `ScreenCaptureService`: ScreenCaptureKit capture of the display under the
  cursor, cropped in pixel space to the selected region and PNG-encoded, plus a
  downscaled-JPEG full-display capture for the assistant
- `Assistant/AssistantController`: hold-to-talk orchestration (listen → capture
  → Claude → speak/show)
- `Assistant/AssistantHotkeyMonitor`: press-and-hold Option–Command–C chord
  tracking
- `Assistant/AssistantPanel`: non-activating status/answer panel with
  text input
- `Assistant/SpeechService`: on-device speech-to-text (Apple Speech framework)
- `Assistant/AnthropicService`: Anthropic Messages REST client (vision + text)
- `Assistant/KeychainService`: reads the Anthropic API key + workspace ID from the
  macOS Keychain; `adoptIfNeeded` re-saves items under the app's ownership so
  Keychain never prompts again after the first "Always Allow"
- `Assistant/RemoteControlService`: Bonjour TCP listener for the iOS remote
- `Assistant/ActivityLog`: local JSONL activity log powering ClickyLogs
- `Assistant/GoogleAuthService`: Google OAuth 2.0 for a native app (PKCE +
  loopback redirect); refresh token in Keychain, access token in memory
- `Assistant/GmailService`: Gmail REST client, builds a read-only inbox digest,
  finds large messages and empties Trash/Spam for Gmail Cleanup
- `Assistant/DriveService`: Drive REST client — fetch a file's full text, look
  up file metadata, move a file to the trash, read the account's storage
  quota, empty the trash permanently
- `Assistant/DriveCleanupPanel`: Drive Cleanup review window (⌥⌘D) — quota
  meter, candidate table, trash and empty-trash confirmations
- `Assistant/DriveCleanupPlanner`: heuristics + Claude shortlist behind Drive
  Cleanup
- `Assistant/GmailCleanupPanel`: Gmail Cleanup review window (⌥⌘G) for large
  messages, mirroring `DriveCleanupPanel`
- `Assistant/BrowserTabReader`: reads the active tab URL from Chrome, Safari,
  Arc, Edge, or Brave via Apple Events, used to detect an open Drive file
- `Assistant/EditorContextReader`: reads the focused file's text from a
  frontmost code editor via the Accessibility API
- `Assistant/HighlightRingController`: draws a glowing ring over an on-screen
  element Claude located, for "click it" and answer highlights
- `Assistant/ConfirmActionPanel`: confirmation dialog gating mouse clicks and
  Drive trash actions before they execute
- `Assistant/MouseClicker`: synthesizes a real mouse click at a screen point
- `Assistant/SyntaxHighlighter`: regex highlighter for the Code tab; theme
  and language tables are extensible at runtime
- `Assistant/Extensions/ExtensionManifest`: the `manifest.json` schema
  (languages, themes, formatters, linters, actions) and its validation
- `Assistant/Extensions/ExtensionManager`: discovers, loads, enables and
  installs/uninstalls extension folders; publishes an `ExtensionRegistry`
- `Assistant/Extensions/ExtensionScriptRunner`: runs extension scripts,
  formatters and linters with a timeout, params and `PEEKY_*` environment
- `Assistant/Extensions/ExtensionMarketplace`: fetches and searches the
  remote extension catalog
- `Assistant/Extensions/ExtensionsView`: the Ext tab (installed list, code
  theme picker, marketplace)

This is an MVP foundation. A hardened distribution should add an app target
with sandbox entitlements, code signing, a settings UI for the destination
folder and hotkey, and multi-display selection support.

## Inspiration and attribution

MyClicky is inspired by **[HeyClicky](https://www.heyclicky.com)**, the
on-screen voice assistant for the Mac created by **Farza Majeed** (founder of
buildspace; Founders, Inc.). The idea of an assistant that sits near your
cursor, sees your screen, and talks you through tasks comes from there.

MyClicky is an independent implementation written from scratch in Swift. It is
a personal project, is **not affiliated with, endorsed by, or derived from**
HeyClicky or its authors, and shares no code with it. "HeyClicky" is the
property of its respective owner; the name "MyClicky" is used only to mark this
as a personal take on the same idea.
