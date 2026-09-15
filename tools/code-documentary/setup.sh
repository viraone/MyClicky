#!/usr/bin/env bash
# Installs the code-documentary pipeline where Peeky's "Peeky Code Documentary"
# tab looks for it (~/code-documentary by default; pass another path as $1).
#
#   tools/code-documentary/setup.sh [target-dir]
#
# Needs Homebrew (for espeak-ng, ffmpeg, pango) and python3.12.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
target="${1:-$HOME/code-documentary}"
python="${PYTHON:-python3.12}"

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
command -v "$python" >/dev/null || { echo "$python not found — brew install python@3.12"; exit 1; }

echo "==> brew deps"
for pkg in ffmpeg espeak-ng pango cairo pkgconf; do
  brew list "$pkg" >/dev/null 2>&1 || brew install -q "$pkg"
done

echo "==> copying pipeline to $target"
mkdir -p "$target/projects"
cp "$here"/{documentary.py,illustrations.py,narrate.py,make_doc.py,build.sh} "$target/"
chmod +x "$target/build.sh"
[ -f "$target/script.json" ] || cp "$here/script.json" "$target/"

echo "==> python venv"
if [ ! -x "$target/.venv/bin/python" ]; then
  "$python" -m venv "$target/.venv"
fi
"$target/.venv/bin/pip" install -q --upgrade pip
"$target/.venv/bin/pip" install -q manim kokoro soundfile

echo "==> warming up Kokoro (downloads the voice model once)"
"$target/.venv/bin/python" - <<'EOF' 2>/dev/null || echo "   (Kokoro warm-up skipped; it will download on first use)"
from kokoro import KPipeline
KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
EOF

if [ "$target" != "$HOME/code-documentary" ]; then
  echo "==> tell Peeky where it lives:"
  echo "    defaults write MyClicky documentaryPipelineDir \"$target\""
fi
echo "==> done. Open Peeky → Peeky Code Doc."
