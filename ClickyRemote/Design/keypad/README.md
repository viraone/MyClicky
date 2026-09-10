Keypad visual verification
==========================

The requested iPhone 17 simulator build passed with code signing disabled:

```sh
cd ClickyRemote && xcodebuild -project ClickyRemote.xcodeproj -scheme ClickyRemote -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/peeky-derived-ClickyRemote CODE_SIGNING_ALLOWED=NO -quiet build
```

The five `after-*.png` screenshots show idle, ASK recording, DICTATE recording, TALK recording, and PHOTOS saving on iPhone 17 at Dynamic Type Large (iOS 26.5). The same five states were checked on iPhone SE (3rd generation) at Large. Per-device matrix PNGs were removed to keep this folder small; `before.png` retains the original layout reference.

Screenshots use a temporary fixture copy that seeds recording target, listening state, microphone level (0.65), and saving state at launch without connecting to the Mac or requesting permissions. No fixture code is included in the production app. These checks verify presentation, not microphone transcription or end-to-end photo transfer.

Idle tiles use saturated gradients with white icons and heavy labels. Recording uses a solid red face (brighter for DICTATE), a stronger white rim, the existing waveform, and the existing pulse. Saving PHOTOS uses a brighter blue face and stronger rim without a pulse. Tile layout, palette values, actions, and other controls are unchanged.

Visual limitation: with the requested larger fonts/icons and unchanged 14pt inner padding, the PHOTOS icon touches its label in the 64pt row on both devices, and CAPTURE truncates on SE during recording. Correcting this requires a small inner-padding adjustment beyond the requested styling-only scope.
