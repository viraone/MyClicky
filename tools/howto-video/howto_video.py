#!/usr/bin/env python3
"""Data-driven how-to video generator: frames, narration, and build in one script."""
import json
import math
import os
import subprocess
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# --- constants (copied from frames.py) ---
W, H = 1080, 1920
BG = (16, 20, 26)
WHITE = (255, 255, 255)
SOFT = (200, 208, 218)
RED = (225, 40, 40)
LINK = (255, 205, 80)
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_NARROW = "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf"

TOP_BAND = 300
PHONE_H = 1300
BOTTOM_TOP = TOP_BAND + PHONE_H


def font(size, path=FONT_BOLD):
    return ImageFont.truetype(path, size)


def wrap(draw, text, fnt, max_w):
    lines = _wrap(draw, text, fnt, max_w)
    n = len(lines)
    if n > 1:
        w = max_w
        while w > 200:
            w -= 10
            trial = _wrap(draw, text, fnt, w)
            if len(trial) != n or max(draw.textlength(t, font=fnt) for t in trial) > max_w:
                break
            lines = trial
    return lines


def _wrap(draw, text, fnt, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=fnt) <= max_w:
            cur = t
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def fit_caption(draw, text, max_w, max_lines=2, start=72, minimum=64):
    for path in (FONT_BOLD, FONT_NARROW):
        for size in range(start, minimum - 1, -2):
            f = font(size, path)
            lines = wrap(draw, text, f, max_w)
            if len(lines) <= max_lines:
                return f, size, lines, path
    raise SystemExit(f"caption does not fit in {max_lines} lines at >= {minimum}px: {text!r}")


def centered_lines(draw, lines, fnt, y, color=WHITE, gap=14):
    for ln in lines:
        w = draw.textlength(ln, font=fnt)
        draw.text(((W - w) / 2, y), ln, font=fnt, fill=color)
        y += fnt.size + gap
    return y


def load_storyboard(path):
    try:
        with open(path) as f:
            sb = json.load(f)
    except Exception as e:
        print(f"storyboard: missing {path}", file=sys.stderr)
        sys.exit(1)
    for key in ("name", "assets_dir", "url", "title", "steps", "end"):
        if key not in sb:
            print(f"storyboard: missing {key}", file=sys.stderr)
            sys.exit(1)
    sb["assets_dir"] = os.path.expanduser(sb["assets_dir"])
    for step in sb["steps"]:
        if "image" not in step:
            print("storyboard: missing image", file=sys.stderr)
            sys.exit(1)
        img_path = Path(sb["assets_dir"]) / step["image"]
        if not img_path.exists():
            print(f"storyboard: missing {img_path}", file=sys.stderr)
            sys.exit(1)
    return sb


def render_frames(sb, work_dir):
    frames_dir = work_dir / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    assets = Path(sb["assets_dir"])
    url = sb["url"]
    out = []

    # title
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    f, size, lines, _ = fit_caption(d, sb["title"]["caption"], 920, max_lines=3, start=104, minimum=90)
    y = 560
    y = centered_lines(d, lines, f, y)
    y += 40
    y = centered_lines(d, [sb["title"]["subtitle"]], font(64), y, color=SOFT)
    y += 90
    lf = font(52)
    if d.textlength(url, font=lf) > 960:
        lf = font(46)
    w = d.textlength(url, font=lf)
    d.rounded_rectangle([(W - w) / 2 - 36, y - 20, (W + w) / 2 + 36, y + lf.size + 28], radius=26, outline=LINK, width=4)
    d.text(((W - w) / 2, y), url, font=lf, fill=LINK)
    p = frames_dir / "01-title.png"
    img.save(p)
    out.append(p)

    # steps
    for i, step in enumerate(sb["steps"], 1):
        n = i
        caption = step["caption"]
        image_name = step["image"]
        tip = step.get("tip")
        card = step.get("card", False)
        img = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(img)
        r = 52
        cx, cy = 48 + r, TOP_BAND // 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=RED)
        nf = font(72)
        nw = d.textlength(str(n), font=nf)
        d.text((cx - nw / 2, cy - 40), str(n), font=nf, fill=WHITE, anchor="la")
        text_x = cx + r + 32
        max_w = W - text_x - 40
        f, size, lines, path = fit_caption(d, caption, max_w)
        block_h = len(lines) * size + (len(lines) - 1) * 12
        y = cy - block_h / 2 - 6
        for ln in lines:
            d.text((text_x, y), ln, font=f, fill=WHITE)
            y += size + 12
        shot = Image.open(assets / image_name).convert("RGB")
        if card:
            tw = 940
            th = round(shot.height * tw / shot.width)
            shot = shot.resize((tw, th), Image.LANCZOS)
            mask = Image.new("L", shot.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, tw - 1, th - 1], radius=44, fill=255)
            x = (W - tw) // 2
            y0 = TOP_BAND + (PHONE_H - th) // 2
            img.paste(shot, (x, y0), mask)
        else:
            th = PHONE_H
            tw = round(shot.width * th / shot.height)
            shot = shot.resize((tw, th), Image.LANCZOS)
            img.paste(shot, ((W - tw) // 2, TOP_BAND))
        if tip:
            tf = font(46)
            lines = wrap(d, tip, tf, W - 120)
            centered_lines(d, lines, tf, BOTTOM_TOP + 40, color=SOFT)
        p = frames_dir / f"{i + 1:02d}-step{i}.png"
        img.save(p)
        out.append(p)

    # end
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    f1 = font(120)
    y = 600
    y = centered_lines(d, [sb["end"]["headline"]], f1, y)
    y += 40
    f2 = font(68)
    lines = wrap(d, sb["end"]["caption"], f2, 900)
    y = centered_lines(d, lines, f2, y, color=WHITE)
    y += 80
    lf = font(52)
    if d.textlength(url, font=lf) > 960:
        lf = font(46)
    w = d.textlength(url, font=lf)
    d.rounded_rectangle([(W - w) / 2 - 36, y - 20, (W + w) / 2 + 36, y + lf.size + 28], radius=26, outline=LINK, width=4)
    d.text(((W - w) / 2, y), url, font=lf, fill=LINK)
    p = frames_dir / f"{len(sb['steps']) + 2:02d}-end.png"
    img.save(p)
    out.append(p)

    return out


def narrate(sb, work_dir):
    audio_dir = work_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    os.environ["TTS_ENGINE"] = "kokoro"
    sys.path.insert(0, os.path.expanduser("~/code-documentary"))
    import narrate
    narrate.KOKORO_SPEED = 0.95
    texts = [sb["title"]["spoken"]]
    for step in sb["steps"]:
        texts.append(step["spoken"])
    texts.append(sb["end"]["spoken"])
    out = []
    try:
        for i, t in enumerate(texts, 1):
            p = audio_dir / f"s{i}.wav"
            narrate.kokoro_tts(t, p)
            out.append(p)
    except Exception as e:
        print(f"narration failed: {e}", file=sys.stderr)
        return None
    return out


def build(sb, frames, audio, work_dir, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    clips_dir = work_dir / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    mins = [sb["title"]["min_seconds"]]
    for step in sb["steps"]:
        mins.append(step["min_seconds"])
    mins.append(sb["end"]["min_seconds"])

    def dur(p):
        return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(p)]).decode())

    D = []
    for i, (f, m) in enumerate(zip(frames, mins), 1):
        if audio:
            d = max(m, dur(audio[i - 1]) + 0.4 + 0.7)
        else:
            d = m
        D.append(math.ceil(d * 30) / 30)

    def run(*a):
        subprocess.run(["ffmpeg", "-y", "-v", "error", *map(str, a)], check=True)

    lst, alst = [], []
    for i, (f, d) in enumerate(zip(frames, D), 1):
        out = clips_dir / f"v{i}.mp4"
        run("-loop", "1", "-framerate", "30", "-t", f"{d}", "-i", f,
            "-vf", f"fade=t=in:st=0:d=0.35,fade=t=out:st={d - 0.35}:d=0.35,format=yuv420p",
            "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-r", "30", "-pix_fmt", "yuv420p", out)
        lst.append(f"file '{out}'")
        if audio:
            aout = clips_dir / f"a{i}.wav"
            run("-i", audio[i - 1], "-af", f"adelay=400|400,apad=whole_dur={d}", "-t", f"{d}", "-ar", "44100", "-ac", "2", aout)
            alst.append(f"file '{aout}'")

    v_txt = work_dir / "v.txt"
    v_txt.write_text("\n".join(lst) + "\n")
    video_only = work_dir / "video_only.mp4"
    run("-f", "concat", "-safe", "0", "-i", v_txt, "-c", "copy", video_only)

    total = sum(D)
    name = sb["name"]
    common = ["-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-movflags", "+faststart"]
    silent = out_dir / f"{name}.mp4"
    run("-i", video_only, "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", f"{total}", *common, "-shortest", silent)
    outputs = [silent]
    if audio:
        a_txt = work_dir / "a.txt"
        a_txt.write_text("\n".join(alst) + "\n")
        narration = work_dir / "narration.wav"
        run("-f", "concat", "-safe", "0", "-i", a_txt, "-c", "copy", narration)
        narrated = out_dir / f"{name}-narrated.mp4"
        run("-i", video_only, "-i", narration, *common, "-shortest", narrated)
        outputs.append(narrated)
    return outputs


def main(argv):
    if len(argv) < 2:
        print("usage: python howto_video.py STORYBOARD.json [--out-dir DIR] [--work-dir DIR] [--silent-only]", file=sys.stderr)
        return 1
    sb_path = argv[1]
    out_dir = Path.home() / "Downloads"
    work_dir = None
    silent_only = False
    i = 2
    while i < len(argv):
        if argv[i] == "--out-dir" and i + 1 < len(argv):
            out_dir = Path(argv[i + 1])
            i += 2
        elif argv[i] == "--work-dir" and i + 1 < len(argv):
            work_dir = Path(argv[i + 1])
            i += 2
        elif argv[i] == "--silent-only":
            silent_only = True
            i += 1
        else:
            i += 1
    sb = load_storyboard(sb_path)
    if work_dir is None:
        work_dir = Path.home() / ".cache" / "howto-video" / sb["name"]
    work_dir.mkdir(parents=True, exist_ok=True)
    frames = render_frames(sb, work_dir)
    audio = None if silent_only else narrate(sb, work_dir)
    outputs = build(sb, frames, audio, work_dir, out_dir)
    total = 0.0
    for p in outputs:
        probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration,size", "-show_entries", "stream=codec_type,codec_name,width,height", "-of", "json", str(p)]).decode()
        data = json.loads(probe)
        dur = float(data["format"]["duration"])
        total = max(total, dur)
        size_mb = int(data["format"]["size"]) / 1e6
        streams = data["streams"]
        vcodec = next((s["codec_name"] for s in streams if s.get("codec_type") == "video"), "?")
        acodec = next((s["codec_name"] for s in streams if s.get("codec_type") == "audio"), "?")
        width = next((s.get("width", "?") for s in streams if s.get("codec_type") == "video"), "?")
        height = next((s.get("height", "?") for s in streams if s.get("codec_type") == "video"), "?")
        print(f"{p}: {dur:.2f}s, {width}x{height}, {vcodec}/{acodec}, {size_mb:.2f} MB")
    print(f"total {total:.2f} s")
    if total > 60:
        print("WARNING: over 60 seconds, tighten the narration")
    if audio is None and not silent_only:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

