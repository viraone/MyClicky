Keypad visual verification
==========================

The required iPhone 17 simulator build passed with code signing disabled.

These are simulator screenshots from temporary visual-fixture copies of the app on iOS 26.5. The before copy uses origin/main; the after copy uses the redesigned Swift source. In the copies only, the launch task seeds `recordTarget`, `recorder.isListening`, `recorder.level = 0.65`, and `savingToDesktop` instead of starting the client or requesting permissions; scene resume does not connect. No fixture code is included in the app change. Recording screenshots use an empty transcript. They verify presentation, not microphone transcription or an end-to-end photo transfer.

The grid remains square by narrowing symmetrically when the available height cannot hold full-width squares, the screen switch, the banner and a 64-point photo row. Gaps stay 12 points. The existing fixed-point label fonts intentionally remain fixed at both Dynamic Type settings specified in the design.

`before.png` and `after-*.png` show iPhone 17 at Large, including DICTATE recording. The remaining files cover idle, ASK recording, TALK recording and PHOTOS saving at Large and xxLarge (simctl `extra-extra-large`).

| Simulator | Large | xxLarge |
| --- | --- | --- |
| iPhone SE (3rd generation) | `se-large-*.png` | `se-extra-extra-large-*.png` |
| iPhone 15 | `15-large-*.png` | `15-extra-extra-large-*.png` |
| iPhone 17 | `after-*.png` | `17-extra-extra-large-*.png` |
| iPhone 17 Pro Max | `17-pro-max-large-*.png` | `17-pro-max-extra-extra-large-*.png` |

Visual review checks tile bounds, square proportions, labels, the shorter photo row, and waveform clearance. The shortcut chips retain their existing light tint and coloured glyph treatment. The actions, recording logic, confirm card, other pads, screen-switch internals, palette values and press style remain unchanged.
