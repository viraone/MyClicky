#!/usr/bin/env bash
# Code -> documentary pipeline (single-project shortcut; make_doc.py is the general entry point).
#   1. script.json   : documentary script (written by an LLM)
#   2. documentary.py: Manim animation driven by the script
#   3. narrate.py    : ElevenLabs (if ELEVENLABS_API_KEY set) or macOS `say`
#
# Usage: ./build.sh [-ql|-qm|-qh]   (Manim quality flag, default -qm)
set -euo pipefail
cd "$(dirname "$0")"

QUALITY="${1:--qm}"

echo "==> [3] narration"
.venv/bin/python narrate.py

echo "==> [2] rendering with Manim ($QUALITY)"
.venv/bin/manim "$QUALITY" --disable_caching -o documentary.mp4 documentary.py Documentary

OUT=$(ls -t $(find media/videos -name documentary.mp4) | head -1)
cp "$OUT" ./documentary.mp4
echo "==> done: $(pwd)/documentary.mp4"
