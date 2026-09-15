"""One-shot: project folder (script.json) -> narrated documentary.mp4.

    .venv/bin/python make_doc.py <project_dir> [--quality low|medium|high] [--force-audio]

Progress lines start with "## " so a host app can show them as steps.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent
PY = ROOT / ".venv" / "bin" / "python"
MANIM = ROOT / ".venv" / "bin" / "manim"


def step(msg: str) -> None:
    print(f"## {msg}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--quality", default="high", choices=["low", "medium", "high"])
    ap.add_argument("--force-audio", action="store_true")
    args = ap.parse_args()

    project = Path(args.project).expanduser().resolve()
    if not (project / "script.json").exists():
        print(f"no script.json in {project}", file=sys.stderr)
        return 2

    env = {**os.environ, "DOC_PROJECT": str(project), "PYTHONUNBUFFERED": "1"}

    step("Narrating scenes")
    narrate = [str(PY), str(ROOT / "narrate.py")] + (["--force"] if args.force_audio else [])
    subprocess.run(narrate, env=env, check=True)

    step("Rendering animation with Manim")
    media = project / "media"
    subprocess.run(
        [str(MANIM), {"low": "-ql", "medium": "-qm", "high": "-qh"}[args.quality], "--disable_caching", "--media_dir", str(media),
         "-o", "documentary.mp4", str(ROOT / "documentary.py"), "Documentary"],
        env=env, check=True,
    )

    rendered = sorted(media.rglob("documentary.mp4"), key=lambda p: p.stat().st_mtime)
    if not rendered:
        print("render produced no file", file=sys.stderr)
        return 1
    out = project / "documentary.mp4"
    shutil.copy(rendered[-1], out)
    shutil.rmtree(media / "videos", ignore_errors=True)
    step(f"Done: {out}")
    print(f"OUTPUT {out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
