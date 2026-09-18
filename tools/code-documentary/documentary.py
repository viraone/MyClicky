"""Step 2: render the documentary with Manim.

Reads script.json + audio/durations.json and produces one narrated MP4.
"""

from __future__ import annotations

import json
import os
import textwrap
from pathlib import Path

from manim import (
    DOWN, LEFT, RIGHT, UP, ORIGIN, UL,
    BLACK, GOLD, GREY_B, GREY_C, WHITE,
    Code, FadeIn, FadeOut, Rectangle, Scene, Text, VGroup,
    Write, config, Line,
)

from illustrations import BUILDERS, GENERIC

ROOT = Path(__file__).parent
# A "project" is a folder holding script.json and audio/. Defaults to ROOT.
PROJECT = Path(os.environ.get("DOC_PROJECT", ROOT))
SCRIPT = json.loads((PROJECT / "script.json").read_text())
DURATIONS = json.loads((PROJECT / "audio" / "durations.json").read_text())
SOURCE_LINES = Path(SCRIPT["source"]).read_text().splitlines()
# Pygments lexer for the passages on screen. Peeky writes "text" for a .txt
# documentary; absent means a code file, drawn as before.
LANGUAGE = SCRIPT.get("language") or "typescript"
PROSE = LANGUAGE in ("text", "markdown")
PROSE_WIDTH = 72  # characters per line before a paragraph wraps

config.background_color = "#0b0d12"
ACCENT = "#e50914"  # that streaming-service red
FONT = "Helvetica Neue"
PAD = 0.6


class Documentary(Scene):
    def construct(self) -> None:
        # Wall-clock range of every scene, so a host app can map a paused
        # timestamp back to the chapter, its code lines and narration.
        timeline = []
        for scene in SCRIPT["scenes"]:
            start = self._clock()
            getattr(self, f"scene_{scene['kind']}")(scene)
            timeline.append({"id": scene["id"], "start": round(start, 2), "end": round(self._clock(), 2)})
        (PROJECT / "timeline.json").write_text(json.dumps({"scenes": timeline}, indent=2))

    def _clock(self) -> float:
        t = getattr(self.renderer, "time", None)
        return float(t if t is not None else getattr(self, "time", 0.0))

    # ---- helpers ---------------------------------------------------------

    def narrate(self, scene: dict, already_used: float = 0.0) -> None:
        """Wait out the rest of this scene's narration."""
        remaining = DURATIONS[scene["id"]] - already_used + PAD
        if remaining > 0:
            self.wait(remaining)

    def heading(self, text: str) -> VGroup:
        label = Text(text.upper(), font=FONT, weight="BOLD", font_size=22, color=GREY_B)
        label.to_edge(UP, buff=0.35).to_edge(LEFT, buff=0.6)
        bar = Line(LEFT, RIGHT, color=ACCENT, stroke_width=4).set_length(0.5)
        bar.next_to(label, LEFT, buff=0.2)
        return VGroup(bar, label)

    def clear(self) -> None:
        if self.mobjects:
            self.play(FadeOut(*self.mobjects, run_time=0.6))

    # ---- scene kinds -----------------------------------------------------

    def scene_title(self, scene: dict) -> None:
        self.add_sound(str(PROJECT / "audio" / f"{scene['id']}.wav"))
        bar = Rectangle(width=0.12, height=2.2, fill_color=ACCENT, fill_opacity=1, stroke_width=0)
        title = Text(SCRIPT["title"], font=FONT, weight="BOLD", font_size=72, color=WHITE)
        sub = Text(SCRIPT["subtitle"], font=FONT, font_size=26, color=GREY_B)
        block = VGroup(title, sub).arrange(DOWN, aligned_edge=LEFT, buff=0.35)
        group = VGroup(bar, block).arrange(RIGHT, buff=0.5).move_to(ORIGIN)

        self.play(FadeIn(bar, shift=UP * 0.3), run_time=0.8)
        self.play(Write(title), run_time=1.6)
        self.play(FadeIn(sub, shift=UP * 0.2), run_time=0.8)
        self.narrate(scene, already_used=3.2)
        self.clear()

    def scene_code(self, scene: dict) -> None:
        self.add_sound(str(PROJECT / "audio" / f"{scene['id']}.wav"))
        start, end = scene["lines"]
        raw = SOURCE_LINES[start - 1 : end]
        if PROSE:
            # Paragraphs are one long line each; wrap so they read like a page
            # rather than a ribbon shrunk to fit, and drop the line numbers.
            raw = [textwrap.fill(line, PROSE_WIDTH) if line.strip() else "" for line in raw]
        snippet = "\n".join(raw)
        if not snippet.strip():
            snippet = "[Source passage unavailable]"
        code = Code(
            code_string=snippet,
            language=LANGUAGE,
            formatter_style="monokai",
            add_line_numbers=not PROSE,
            line_numbers_from=start,
            background="rectangle",
            background_config={"fill_color": "#12151d", "stroke_color": "#2a2f3a", "stroke_width": 1},
            paragraph_config={"font": "Menlo", "font_size": 20},
        )
        builder = BUILDERS.get(scene["id"])
        spec = scene.get("illustration")
        if not builder and spec and spec.get("type") in GENERIC:
            generic = GENERIC[spec["type"]]
            builder = lambda region, _g=generic, _s=spec: _g(region, _s)
        if builder:
            # Code on the left ~58%, illustration on the right.
            max_w, max_h = 7.6, config.frame_height - 2.0
            region = Rectangle(width=5.2, height=5.6).move_to(RIGHT * 4.3 + DOWN * 0.2)
        else:
            max_w, max_h = config.frame_width - 1.2, config.frame_height - 2.0
            region = None
        if code.width > max_w:
            code.scale_to_fit_width(max_w)
        if code.height > max_h:
            code.scale_to_fit_height(max_h)
        if builder:
            code.move_to(LEFT * 2.9 + DOWN * 0.2)
        else:
            code.move_to(ORIGIN).shift(DOWN * 0.2)

        head = self.heading(scene["heading"])
        self.play(FadeIn(head, shift=RIGHT * 0.2), run_time=0.6)
        self.play(FadeIn(code, shift=UP * 0.3), run_time=1.0)

        beats: list = []
        if builder:
            illo, beats = builder(region)
            if illo.width > region.width:
                illo.scale_to_fit_width(region.width)
            if illo.height > region.height:
                illo.scale_to_fit_height(region.height)
            illo.move_to(region)

        # Sweep a highlight down the lines while the narrator talks.
        lines = [l for l in code.code_lines if len(l.get_all_points()) > 0]
        sweep_time = max(DURATIONS[scene["id"]] - 2.0, 1.0)
        n_moves = max(len(lines) - 1, 1)
        beat_time = 0.9 * len(beats)
        per_line = max((sweep_time - beat_time) / n_moves, 0.2)
        beat_at = {round(i * n_moves / max(len(beats), 1)): b for i, b in enumerate(beats)}
        line_h = max(l.height for l in lines) + 0.14
        box = Rectangle(
            width=code.width - 0.2, height=line_h,
            fill_color=ACCENT, fill_opacity=0.18, stroke_color=ACCENT, stroke_width=1.5,
        )
        box.move_to(code).set_y(lines[0].get_y())
        self.play(FadeIn(box), run_time=0.4)
        loop_time = 0.0
        for idx, line in enumerate(lines[1:]):
            if idx in beat_at:
                self.play(*beat_at.pop(idx), run_time=0.9)
                loop_time += 0.9
            move = min(per_line, 1.2)
            self.play(box.animate.set_y(line.get_y()), run_time=move, rate_func=lambda t: t)
            loop_time += move
            if per_line > 1.2:
                self.wait(per_line - 1.2)
                loop_time += per_line - 1.2
        for b in beat_at.values():
            self.play(*b, run_time=0.9)
            loop_time += 0.9
        used = 0.6 + 1.0 + 0.4 + loop_time
        self.narrate(scene, already_used=used)
        self.clear()

    def scene_example(self, scene: dict) -> None:
        self.add_sound(str(PROJECT / "audio" / f"{scene['id']}.wav"))
        head = self.heading(scene["heading"])
        self.play(FadeIn(head, shift=RIGHT * 0.2), run_time=0.6)

        rows = VGroup()
        for label, value in scene["steps"]:
            lab = Text(label, font=FONT, font_size=24, color=GREY_B)
            val = Text(value, font="Menlo", font_size=26, color=WHITE)
            row = VGroup(lab, val).arrange(DOWN, aligned_edge=LEFT, buff=0.12)
            rows.add(row)
        rows.arrange(DOWN, aligned_edge=LEFT, buff=0.42).move_to(ORIGIN).shift(DOWN * 0.2)
        if rows.height > config.frame_height - 2.0:
            rows.scale_to_fit_height(config.frame_height - 2.0)

        per_step = (DURATIONS[scene["id"]] - 0.6) / len(rows)
        for row in rows:
            self.play(FadeIn(row, shift=UP * 0.2), run_time=0.7)
            self.wait(max(per_step - 0.7, 0.1))
        rows[-1][1].set_color(GOLD)
        self.wait(PAD)
        self.clear()

    def scene_list(self, scene: dict) -> None:
        self.add_sound(str(PROJECT / "audio" / f"{scene['id']}.wav"))
        head = self.heading(scene["heading"])
        self.play(FadeIn(head, shift=RIGHT * 0.2), run_time=0.6)

        items = VGroup()
        for i, text in enumerate(scene["items"], start=1):
            num = Text(f"{i:02d}", font=FONT, weight="BOLD", font_size=40, color=ACCENT)
            body = Text(text, font=FONT, font_size=30, color=WHITE)
            items.add(VGroup(num, body).arrange(RIGHT, buff=0.4, aligned_edge=DOWN))
        items.arrange(DOWN, aligned_edge=LEFT, buff=0.55).move_to(ORIGIN)
        if items.width > config.frame_width - 1.2:
            items.scale_to_fit_width(config.frame_width - 1.2)

        per_item = (DURATIONS[scene["id"]] - 0.6) / len(items)
        for item in items:
            self.play(FadeIn(item, shift=RIGHT * 0.3), run_time=0.7)
            self.wait(max(per_item - 0.7, 0.1))
        self.wait(PAD)
        self.clear()

    def scene_credits(self, scene: dict) -> None:
        self.add_sound(str(PROJECT / "audio" / f"{scene['id']}.wav"))
        title = Text(SCRIPT["title"], font=FONT, weight="BOLD", font_size=56, color=WHITE)
        lines = [
            ("Based on", Path(SCRIPT["source"]).name),
            ("Script", "LLM"),
            ("Animation", "Manim Community"),
            ("Narration", "ElevenLabs / macOS say"),
        ]
        credits = VGroup()
        for role, name in lines:
            r = Text(role.upper(), font=FONT, font_size=18, color=GREY_C)
            n = Text(name, font=FONT, font_size=26, color=WHITE)
            credits.add(VGroup(r, n).arrange(DOWN, buff=0.08))
        credits.arrange(DOWN, buff=0.4)
        group = VGroup(title, credits).arrange(DOWN, buff=0.9).move_to(ORIGIN)

        self.play(FadeIn(title), run_time=1.0)
        self.play(FadeIn(credits, shift=UP * 0.3), run_time=1.2)
        self.narrate(scene, already_used=2.2)
        self.play(FadeOut(group), run_time=1.2)
