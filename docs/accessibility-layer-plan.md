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
      verified live over the Bonjour socket: Claude planned it, `AppDriver`
      launched/foregrounded Mail (then TextEdit) and `STATUS` streamed back.
      Still needs an on-screen check with a real inbox (the Mac was locked
      when this was tested) before calling the reply+send path proven.

## Phase 2 status
- [x] `RemoteControlService`/`AssistantController`: `DO`, `CONFIRM_OK`/
      `CONFIRM_NO`, `READ` wired, with `STATUS`/`CONFIRM`/`READ` streamed back
- [x] iOS: TALK mode in `NumpadView` (big button, Dynamic Type, VoiceOver
      labels), STATUS/READ shown in large text + spoken via
      `AVSpeechSynthesizer` (now in `ClickyClient`), CONFIRM as two huge
      Yes/No buttons, "What does it say?" sends `READ`
- [ ] Run the iOS build on-device and try the full demo flow for real
