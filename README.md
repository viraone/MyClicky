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

**Hold** Option–Command–C, speak your question, release to submit. A floating
panel appears with a status dot (cyan idle → red listening → yellow thinking →
green answering). Your voice is transcribed on-device (Apple Speech), the
screen under your cursor is captured, and both are sent to Claude in one
request. The answer is spoken aloud and shown in the panel. You can also type
a question in the panel's text field instead of speaking. Press Escape to
dismiss the panel.

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
panel's **Dictate** tab. The panel has three tabs: Ask, Dictate, Capture.

## Clicky Remote (iOS app)

`ClickyRemote/` is a companion iPhone numpad app (open `ClickyRemote.xcodeproj`
in Xcode, run on the phone with ⌘R after any change). It finds the Mac via
Bonjour (`_clicky._tcp`) and sends newline-terminated text commands
(`RemoteControlService`). Keys: 0 = show Ask tab, 1 = mic toggle,
2 = Dictate mode, 3 = Capture, enter = collapse panel.

## ClickyLogs (weekly dashboard)

Every ask/dictate/capture/click is logged (with the site you used Clicky on)
to `~/Library/Application Support/MyClicky/ClickyLogs/*.jsonl` by
`Assistant/ActivityLog`, plus a once-a-minute frontmost-app sample.
The dashboard lives at
`~/Library/Application Support/MyClicky/ClickyLogsSite/index.html`
(bookmark it); a LaunchAgent (`com.myclicky.clickylogs`) regenerates
`data.js` every 5 minutes. Source is in `ClickyLogs/`; after editing it run
`./scripts/clickylogs.sh` to reinstall and open it. Data never leaves the Mac.

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
- `Assistant/AssistantPanel`: floating non-activating status/answer panel with
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
- `Assistant/GmailService`: Gmail REST client, builds a read-only inbox digest
- `Assistant/DriveService`: Drive REST client — fetch a file's full text, look
  up file metadata, move a file to the trash
- `Assistant/BrowserTabReader`: reads the active tab URL from Chrome, Safari,
  Arc, Edge, or Brave via Apple Events, used to detect an open Drive file
- `Assistant/EditorContextReader`: reads the focused file's text from a
  frontmost code editor via the Accessibility API
- `Assistant/HighlightRingController`: draws a glowing ring over an on-screen
  element Claude located, for "click it" and answer highlights
- `Assistant/ConfirmActionPanel`: confirmation dialog gating mouse clicks and
  Drive trash actions before they execute
- `Assistant/MouseClicker`: synthesizes a real mouse click at a screen point

This is an MVP foundation. A hardened distribution should add an app target
with sandbox entitlements, code signing, a settings UI for the destination
folder and hotkey, and multi-display selection support.
