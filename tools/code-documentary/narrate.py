"""Step 3: generate narration audio for each scene.

Engines (pick with TTS_ENGINE=kokoro|elevenlabs|say):
  - kokoro     : local neural TTS (default)
  - elevenlabs : used automatically when ELEVENLABS_API_KEY is set
  - say        : macOS built-in fallback
Writes audio/<scene_id>.wav and audio/durations.json.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).parent
PROJECT = Path(os.environ.get("DOC_PROJECT", ROOT))
AUDIO = PROJECT / "audio"
SAY_VOICE = os.environ.get("SAY_VOICE", "Ava (Premium)")
ELEVEN_KEY = os.environ.get("ELEVENLABS_API_KEY")
ELEVEN_VOICE = os.environ.get("ELEVENLABS_VOICE_ID", "onwK4e9ZLuTAKqWW03F9")  # "Daniel"
# Kokoro voices: am_michael, am_adam, am_fenrir, af_heart, af_bella, bm_george, bf_emma ...
KOKORO_VOICE = os.environ.get("KOKORO_VOICE", "am_michael")
KOKORO_SPEED = float(os.environ.get("KOKORO_SPEED", "0.95"))
ENGINE = os.environ.get("TTS_ENGINE", "elevenlabs" if ELEVEN_KEY else "kokoro")

_kokoro_pipeline = None


def kokoro_tts(text: str, out: Path) -> None:
    global _kokoro_pipeline
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline

    if _kokoro_pipeline is None:
        _kokoro_pipeline = KPipeline(lang_code=KOKORO_VOICE[0], repo_id="hexgrad/Kokoro-82M")
    chunks = []
    pause = np.zeros(int(24000 * 0.35), dtype=np.float32)
    for _, _, audio in _kokoro_pipeline(text, voice=KOKORO_VOICE, speed=KOKORO_SPEED):
        chunks += [np.asarray(audio, dtype=np.float32), pause]
    sf.write(out, np.concatenate(chunks), 24000)


def eleven_labs(text: str, out: Path) -> None:
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVEN_VOICE}",
        data=json.dumps(
            {"text": text, "model_id": "eleven_multilingual_v2"}
        ).encode(),
        headers={"xi-api-key": ELEVEN_KEY, "Content-Type": "application/json"},
    )
    mp3 = out.with_suffix(".mp3")
    with urllib.request.urlopen(req) as resp:
        mp3.write_bytes(resp.read())
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp3, out], check=True)
    mp3.unlink()


def mac_say(text: str, out: Path) -> None:
    aiff = out.with_suffix(".aiff")
    subprocess.run(["say", "-v", SAY_VOICE, "-r", "165", "-o", aiff, text], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", aiff, out], check=True)
    aiff.unlink()


def duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def main() -> None:
    script = json.loads((PROJECT / "script.json").read_text())
    AUDIO.mkdir(exist_ok=True)
    engine = {"elevenlabs": eleven_labs, "kokoro": kokoro_tts, "say": mac_say}[ENGINE]
    label = {"elevenlabs": "ElevenLabs", "kokoro": f"Kokoro ({KOKORO_VOICE})", "say": f"macOS say ({SAY_VOICE})"}[ENGINE]
    print(f"narration engine: {label}")

    durations: dict[str, float] = {}
    for scene in script["scenes"]:
        out = AUDIO / f"{scene['id']}.wav"
        if not out.exists() or "--force" in sys.argv:
            engine(scene["narration"], out)
        durations[scene["id"]] = duration(out)
        print(f"  {scene['id']:<20} {durations[scene['id']]:6.2f}s")

    (AUDIO / "durations.json").write_text(json.dumps(durations, indent=2))
    print(f"total narration: {sum(durations.values()):.1f}s")


if __name__ == "__main__":
    main()
