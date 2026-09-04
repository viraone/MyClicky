# Clicky as the Mac's accessibility layer — build plan

Goal: any app, controlled by voice from an iPhone, for people who can't use a
mouse/keyboard well (ALS, stroke, arthritis, low vision, elderly).
Demo target: hands-free, from a phone — send a WhatsApp photo, reply to an
email, and book a calendar event in under 60 seconds.

## What we already have (the moat)
- AccessibilityFinder: locate controls by label/role in any app, on-screen only
- MouseClicker / KeyboardTyper: real clicks, key presses, clipboard paste
- WhatsAppActions.bringForward: unhide / un-minimize / reopen any app window
- Claude vision: "click the save button" -> bounding box -> ring -> confirm
- RemoteControlService <-> ClickyClient: two-way Bonjour link with the phone
- Phone: on-device speech, Photos picker, camera, haptics, Mac status echo

## Phase 1 — universal actions (replace per-app cartridges)
1. `AXActions.swift`: generic verbs over any frontmost app
   - open(app), focus(field label), click(control label), type(text), press(key)
   - read(screen) -> list of interactive elements (role, label, frame)
2. Claude planner: transcript + AX element list (+ screenshot) -> JSON steps
   using only those verbs. Reuse ConfirmActionPanel before irreversible steps.
3. Remote command `DO <utterance>` — phone sends plain speech, Mac plans+acts.
4. Fallback: if AX can't find it, use existing vision click-it path.

## Phase 2 — the phone as the whole controller
- Big-button "Talk" pad (single button, high contrast, huge text, VoiceOver)
- Mac streams back what it's doing: "Opening Mail… typing… ready to send?"
- Confirm / Cancel on the phone (not the Mac) — the user may not be at the Mac
- Read-aloud of what's on the Mac screen on request ("what does it say?")

## Phase 3 — proof
- 10 real users (a disability org, a few families). Quotes.
- 60-second demo video for the YC application.

## Tomorrow, first hour
- [x] Extract `bringForward` + finder helpers into a generic `AppDriver`
- [x] `AXActions.read()` — dump interactive elements of the frontmost app
- [x] Claude prompt that turns "reply to Mom, tell her I'll be late" into steps
      (`ActionPlanner.swift`)
- [x] `DO` command end-to-end on ONE new app we've never scripted (Mail.app) —
      Claude planned it, `AppDriver` launched/foregrounded Mail, `STATUS`
      streamed back.
- [x] `DO` end-to-end on a SECOND never-scripted app, on-device, with a real
      send: Messages.app, "reply and say so we're meeting tonight at 10 PM my
      time, then send it" — typed into the right conversation, confirm gated
      it, and it actually sent (verified both on screen and in `log show`:
      read → gating irreversible step → requesting confirm → resolved: YES →
      confirmed by user → sent).

## Phase 2 status
- [x] `RemoteControlService`/`AssistantController`: `DO`, `CONFIRM_OK`/
      `CONFIRM_NO`, `READ` wired, with `STATUS`/`CONFIRM`/`READ` streamed back
- [x] iOS: TALK mode in `NumpadView` (big button, Dynamic Type, VoiceOver
      labels), STATUS/READ shown in large text + spoken via
      `AVSpeechSynthesizer` (now in `ClickyClient`), CONFIRM as two huge
      Yes/No buttons, "What does it say?" sends `READ`
- [x] Ran the iOS build on-device and tried the full demo flow for real —
      found and fixed three real bugs along the way: DO results invisible on
      the Mac panel unless the Ask tab was forced, Clicky's own panel
      self-targeting when it became frontmost, and a confirmed irreversible
      step (press return / type) misfiring into the wrong window because
      confirming steals keyboard focus — all fixed in `ActionPlanner.swift`
      and `AssistantController.swift`, confirmed via WhatsApp (photo, reply,
      send) and Messages.app (reply + send) tests

## What's left before the YC demo
- [x] Third leg: create a Calendar event via `DO` — done, but NOT through the
      generic UI path. Calendar's "Create Quick Event" popover never appears
      in the AX window tree at all (verified by dumping all 251 nodes), is
      transient, and couldn't be located reliably from a screenshot across
      ~15 attempts. Now handled by `CalendarActions` via EventKit, exposed as
      a `create_event` planner verb. Verified: "call Verizon" 4-5PM created.
- [x] Vision fallback exercised for real — and it found three genuine bugs it
      was masking (see below)
- [ ] "What does it say?" (`READ`) hasn't been tried on-device yet
- [ ] String together the full demo: WhatsApp photo + Messages reply +
      Calendar event, hands-free, under 60 seconds

## Hard-won lessons from live testing (don't regress these)
- Synthetic input goes to whatever app is frontmost *at that instant*, not the
  app the plan is for. Focus drifts constantly (user clicks, windows opening).
  `Cmd+N` was landing in Chrome for several runs. Every input step now
  reactivates the target app first.
- Never screenshot with Clicky's own panel visible: it contains an empty
  "Ask Clicky anything…" field, which is a perfect decoy when asking Claude to
  find "the empty text field". The DO capture excludes our own windows.
- Screenshot the display the *target app* is on, not `activeScreen` (which
  follows the cursor). On two monitors these differ and you photograph the
  wrong screen.
- Map vision coordinates using the *same* NSScreen the screenshot came from.
  Independently querying `NSScreen.main` silently clicks the wrong place.
- A single Claude vision call misses intermittently even on a clearly visible
  target — retry once before giving up.
- Don't report "Done." unless something actually happened: `AXActions.type`
  verifies an editable element really has focus before pasting.
