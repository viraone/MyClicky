"""Themed illustrations shown beside the code.

Each builder returns (group, beats). `group` is the full illustration (already
positioned); `beats` is an ordered list of animation lists the scene plays as the
narration progresses. Everything sticks to the documentary palette.
"""

from __future__ import annotations

from manim import (
    DOWN, LEFT, RIGHT, UP, ORIGIN, PI,
    GOLD, GREY_B, GREY_C, GREY_D, WHITE,
    Arrow, Circle, Cross, DashedVMobject, FadeIn, FadeOut, GrowFromEdge, Indicate,
    Line, Rectangle, RoundedRectangle, Text, VGroup, Write, Transform,
)

ACCENT = "#e50914"
CARD_BG = "#12151d"
CARD_EDGE = "#2a2f3a"
FONT = "Helvetica Neue"


# ---- primitives ----------------------------------------------------------

def panel(w: float, h: float, edge: str = CARD_EDGE) -> RoundedRectangle:
    return RoundedRectangle(
        width=w, height=h, corner_radius=0.12,
        fill_color=CARD_BG, fill_opacity=1, stroke_color=edge, stroke_width=1.5,
    )


def label(text: str, size: int = 20, color=GREY_B, weight="NORMAL") -> Text:
    return Text(text, font=FONT, font_size=size, color=color, weight=weight)


def mono(text: str, size: int = 18, color=WHITE) -> Text:
    return Text(text, font="Menlo", font_size=size, color=color)


def job_card(w: float = 1.1, h: float = 0.7, hot: bool = False) -> VGroup:
    box = panel(w, h, edge=GOLD if hot else CARD_EDGE)
    title = Line(LEFT, RIGHT, color=WHITE if hot else GREY_B, stroke_width=3).set_length(w * 0.6)
    body = Line(LEFT, RIGHT, color=GREY_D, stroke_width=2).set_length(w * 0.75)
    lines = VGroup(title, body).arrange(DOWN, aligned_edge=LEFT, buff=0.12).move_to(box)
    return VGroup(box, lines)


def card_grid(n: int, cols: int = 3, **kw) -> VGroup:
    g = VGroup(*[job_card(**kw) for _ in range(n)])
    g.arrange_in_grid(rows=(n + cols - 1) // cols, cols=cols, buff=0.15)
    return g


def search_bar(w: float = 4.0, text: str = "") -> VGroup:
    box = panel(w, 0.55)
    glass = VGroup(
        Circle(radius=0.1, color=GREY_B, stroke_width=2),
        Line(ORIGIN, DOWN * 0.12 + RIGHT * 0.12, color=GREY_B, stroke_width=2).shift(DOWN * 0.07 + RIGHT * 0.07),
    ).move_to(box.get_left() + RIGHT * 0.35)
    txt = mono(text, 18).next_to(glass, RIGHT, buff=0.2)
    return VGroup(box, glass, txt)


def browser(w: float = 4.6, h: float = 4.2) -> VGroup:
    frame = panel(w, h)
    bar = Rectangle(width=w, height=0.35, fill_color="#181c26", fill_opacity=1, stroke_width=0)
    bar.move_to(frame.get_top() + DOWN * 0.175)
    dots = VGroup(*[Circle(radius=0.05, fill_color=c, fill_opacity=1, stroke_width=0)
                    for c in (ACCENT, GOLD, GREY_B)]).arrange(RIGHT, buff=0.08)
    dots.move_to(bar.get_left() + RIGHT * 0.4)
    return VGroup(frame, bar, dots)


def chip(text: str) -> VGroup:
    t = mono(text, 20, GOLD)
    box = RoundedRectangle(width=t.width + 0.4, height=0.5, corner_radius=0.25,
                           stroke_color=GOLD, stroke_width=1.5, fill_color=CARD_BG, fill_opacity=1)
    return VGroup(box, t.move_to(box))


def empty_state(w: float = 3.6, h: float = 1.6) -> VGroup:
    box = DashedVMobject(RoundedRectangle(width=w, height=h, corner_radius=0.12,
                                          stroke_color=GREY_C, stroke_width=1.5), num_dashes=40)
    icon = VGroup(Circle(radius=0.22, color=GREY_B, stroke_width=2),
                  Line(ORIGIN, DOWN * 0.25 + RIGHT * 0.25, color=GREY_B, stroke_width=2).shift(DOWN * 0.15 + RIGHT * 0.15))
    txt = label("Nothing found", 20, WHITE)
    inner = VGroup(icon, txt).arrange(DOWN, buff=0.2).move_to(box)
    return VGroup(box, inner)


def caption(text: str) -> Text:
    return label(text, 18, GREY_B)


# ---- illustrations -------------------------------------------------------

def cast(region: Rectangle):
    pw = VGroup(browser(2.0, 1.5), label("Playwright", 20, WHITE, "BOLD")).arrange(DOWN, buff=0.2)
    jp = VGroup(VGroup(panel(2.0, 1.5), card_grid(4, cols=2, w=0.7, h=0.45).scale(0.9)),
                label("JobsPage", 20, WHITE, "BOLD")).arrange(DOWN, buff=0.2)
    pair = VGroup(pw, jp).arrange(RIGHT, buff=0.9)
    arrow = Arrow(pw[0].get_right(), jp[0].get_left(), color=ACCENT, buff=0.1, stroke_width=3)
    tag = caption("drives").next_to(arrow, UP, buff=0.1)
    cap = caption("the test only talks to JobsPage").next_to(pair, DOWN, buff=0.5)
    g = VGroup(pair, arrow, tag, cap).move_to(region)
    return g, [[FadeIn(pw, shift=UP * 0.2)], [FadeIn(jp, shift=UP * 0.2)],
               [GrowFromEdge(arrow, LEFT), FadeIn(tag)], [FadeIn(cap)]]


def nonsense(region: Rectangle):
    bar = search_bar(4.0, "zzzqqqxyz123nonsense")
    grid = card_grid(6, cols=3)
    empty = empty_state()
    stack = VGroup(bar, grid).arrange(DOWN, buff=0.4).move_to(region)
    empty.move_to(grid)
    cap = caption("a term that can never match").next_to(stack, DOWN, buff=0.4)
    g = VGroup(bar, grid, empty, cap)
    return g, [[FadeIn(bar[0]), FadeIn(bar[1]), FadeIn(grid)], [Write(bar[2])],
               [FadeOut(grid), FadeIn(empty)], [FadeIn(cap)]]


def hero_function(region: Rectangle):
    today = VGroup(label("TODAY", 16, GREY_B, "BOLD"), card_grid(4, cols=2)).arrange(DOWN, buff=0.2)
    tomorrow = VGroup(label("TOMORROW", 16, GREY_B, "BOLD"), card_grid(4, cols=2)).arrange(DOWN, buff=0.2)
    cols = VGroup(today, tomorrow).arrange(RIGHT, buff=0.7)
    gone = tomorrow[1][0]
    cross = Cross(gone, stroke_color=ACCENT, stroke_width=4)
    hard = mono('"Frontend Engineer @ Acme"', 15, GREY_C).next_to(cols, DOWN, buff=0.35)
    strike = Line(hard.get_left(), hard.get_right(), color=ACCENT, stroke_width=3)
    live = today[1][0]
    term = chip("Frontend").next_to(hard, DOWN, buff=0.35)
    arrow = Arrow(live.get_bottom(), term.get_left(), color=GOLD, buff=0.1, stroke_width=2.5)
    g = VGroup(cols, cross, hard, strike, term, arrow).move_to(region)
    return g, [[FadeIn(today, shift=UP * 0.2)], [FadeIn(tomorrow, shift=UP * 0.2)],
               [FadeIn(hard)], [FadeIn(cross), FadeOut(gone[1]), gone[0].animate.set_stroke(ACCENT, opacity=0.4), FadeIn(strike)],
               [live[0].animate.set_stroke(GOLD), GrowFromEdge(arrow, UP), FadeIn(term)]]


def test_one_setup(region: Rectangle):
    win = browser(4.6, 4.4)
    bar = search_bar(3.8).move_to(win[0].get_top() + DOWN * 0.8)
    grid = card_grid(12, cols=3, w=1.0, h=0.6).next_to(bar, DOWN, buff=0.3)
    count = chip("12 jobs").move_to(win[0].get_bottom() + UP * 0.35)
    typed = mono("Frontend", 18).move_to(bar[2]).align_to(bar[2], LEFT)
    g = VGroup(win, bar, grid, count, typed).move_to(region)
    return g, [[FadeIn(win), FadeIn(bar[0]), FadeIn(bar[1])], [FadeIn(grid, lag_ratio=0.05)],
               [FadeIn(count, shift=UP * 0.1)], [Write(typed)]]


def test_one_assert(region: Rectangle):
    base = Line(LEFT * 2.2, RIGHT * 2.2, color=GREY_C, stroke_width=2)
    before = Rectangle(width=1.0, height=3.0, fill_color=GREY_B, fill_opacity=0.9, stroke_width=0)
    after = Rectangle(width=1.0, height=1.3, fill_color=ACCENT, fill_opacity=0.95, stroke_width=0)
    before.next_to(base, UP, buff=0).shift(LEFT * 1.1)
    after.next_to(base, UP, buff=0).shift(RIGHT * 1.1)
    lb = label("before", 16).next_to(before, DOWN, buff=0.12)
    la = label("after", 16).next_to(after, DOWN, buff=0.12)
    gt = mono("> 0", 18, GOLD).next_to(after, UP, buff=0.15)
    lt = mono("< before", 18, GOLD).next_to(gt, UP, buff=0.1)
    bad = mono("== 12", 18, GREY_C).next_to(before, UP, buff=0.15)
    strike = Line(bad.get_left(), bad.get_right(), color=ACCENT, stroke_width=3)
    g = VGroup(base, before, after, lb, la, gt, lt, bad, strike).move_to(region)
    return g, [[FadeIn(base), GrowFromEdge(before, DOWN), FadeIn(lb)],
               [GrowFromEdge(after, DOWN), FadeIn(la)],
               [FadeIn(bad), FadeIn(strike)], [FadeIn(gt), FadeIn(lt)]]


def test_one_mentions(region: Rectangle):
    cards = VGroup(*[job_card(0.85, 0.55, hot=i in (1, 4, 7)) for i in range(10)])
    cards.arrange_in_grid(rows=2, cols=5, buff=0.15)
    top = caption("first 10 visible results").next_to(cards, UP, buff=0.3)
    dots = VGroup(*[Circle(radius=0.07, fill_color=GOLD, fill_opacity=1, stroke_width=0)
                    .move_to(cards[i][0].get_corner(UP + RIGHT) + DOWN * 0.12 + LEFT * 0.12) for i in (1, 4, 7)])
    hidden = cards[8]
    tip = VGroup(panel(2.4, 0.5, edge=GREY_C), mono("…in description", 14, GREY_B))
    tip[1].move_to(tip[0])
    tip.next_to(hidden, DOWN, buff=0.25)
    rule = VGroup(mono("mentions >= 1", 18, GOLD), mono("not == 10", 18, GREY_C)).arrange(RIGHT, buff=0.5)
    rule.next_to(tip, DOWN, buff=0.4)
    strike = Line(rule[1].get_left(), rule[1].get_right(), color=ACCENT, stroke_width=3)
    g = VGroup(top, cards, dots, tip, rule, strike).move_to(region)
    return g, [[FadeIn(top), FadeIn(cards, lag_ratio=0.05)],
               [FadeIn(dots, scale=0.5)], [FadeIn(tip, shift=UP * 0.1), Indicate(hidden, color=GREY_B)],
               [FadeIn(rule), FadeIn(strike)]]


def test_two(region: Rectangle):
    win = browser(4.6, 4.0)
    bar = search_bar(3.8, "zzzqqqxyz123nonsense").move_to(win[0].get_top() + DOWN * 0.8)
    grid = card_grid(9, cols=3, w=1.0, h=0.6).next_to(bar, DOWN, buff=0.35)
    empty = empty_state(3.4, 1.8).move_to(grid)
    g = VGroup(win, bar, grid, empty).move_to(region)
    return g, [[FadeIn(win), FadeIn(bar[0]), FadeIn(bar[1]), FadeIn(grid)], [Write(bar[2])],
               [FadeOut(grid)], [FadeIn(empty, shift=UP * 0.1)]]


def test_three(region: Rectangle):
    win = browser(4.6, 4.4)
    bar = search_bar(3.8, "Frontend").move_to(win[0].get_top() + DOWN * 0.8)
    clear = VGroup(Circle(radius=0.14, fill_color=ACCENT, fill_opacity=1, stroke_width=0),
                   Cross(stroke_color=WHITE, stroke_width=2, scale_factor=0.09))
    clear.move_to(bar[0].get_right() + LEFT * 0.3)
    grid = card_grid(12, cols=3, w=1.0, h=0.6).next_to(bar, DOWN, buff=0.3)
    keep = [0, 4, 7, 10]
    drop = VGroup(*[grid[i] for i in range(12) if i not in keep])
    kept = VGroup(*[grid[i] for i in keep])
    g = VGroup(win, bar, clear, grid).move_to(region)
    return g, [[FadeIn(win), FadeIn(bar), FadeIn(grid)],
               [drop.animate.set_opacity(0.08), *[k[0].animate.set_stroke(GOLD) for k in kept]],
               [FadeIn(clear, scale=0.5), Indicate(clear, color=WHITE)],
               [FadeOut(bar[2]), drop.animate.set_opacity(1), *[k[0].animate.set_stroke(CARD_EDGE) for k in kept]]]


BUILDERS = {
    "cast": cast,
    "nonsense": nonsense,
    "hero_function": hero_function,
    "test_one_setup": test_one_setup,
    "test_one_assert": test_one_assert,
    "test_one_mentions": test_one_mentions,
    "test_two": test_two,
    "test_three": test_three,
}


# ---- generic illustrations (chosen from script.json) ----------------------
#
# Each takes (region, spec) where spec is the scene's "illustration" object.
# These let an LLM-written script pick a metaphor without new Python code.

def _rows_reveal(items: list, shift=UP * 0.2) -> list:
    return [[FadeIn(m, shift=shift)] for m in items]


def g_flow(region: Rectangle, spec: dict):
    """Boxes joined by arrows: {"steps": ["parse", "filter", "sort"], "caption": "..."}"""
    steps = spec.get("steps", [])[:5]
    boxes = VGroup()
    for i, text in enumerate(steps):
        t = label(text, 18, WHITE)
        last = i == len(steps) - 1
        box = RoundedRectangle(width=max(t.width + 0.5, 1.6), height=0.7, corner_radius=0.1,
                               fill_color=CARD_BG, fill_opacity=1,
                               stroke_color=GOLD if last else CARD_EDGE, stroke_width=1.5)
        boxes.add(VGroup(box, t.move_to(box)))
    boxes.arrange(DOWN, buff=0.55)
    arrows = VGroup(*[Arrow(boxes[i].get_bottom(), boxes[i + 1].get_top(), color=ACCENT, buff=0.05,
                            stroke_width=3, max_tip_length_to_length_ratio=0.35)
                      for i in range(len(boxes) - 1)])
    parts = [boxes, arrows]
    beats = [[FadeIn(boxes[0], shift=UP * 0.2)]]
    for i in range(1, len(boxes)):
        beats.append([GrowFromEdge(arrows[i - 1], UP), FadeIn(boxes[i], shift=UP * 0.2)])
    if spec.get("caption"):
        cap = caption(spec["caption"]).next_to(boxes, DOWN, buff=0.4)
        parts.append(cap)
        beats.append([FadeIn(cap)])
    return VGroup(*parts).move_to(region), beats


def g_compare(region: Rectangle, spec: dict):
    """Two bars: {"left": {"label": "before", "value": 1.0, "note": "== 12"},
                  "right": {"label": "after", "value": 0.4, "note": "> 0"}, "caption": "..."}"""
    l, r = spec.get("left", {}), spec.get("right", {})
    base = Line(LEFT * 2.2, RIGHT * 2.2, color=GREY_C, stroke_width=2)
    hl = 3.0 * float(l.get("value", 1.0))
    hr = 3.0 * float(r.get("value", 0.5))
    lb = Rectangle(width=1.0, height=max(hl, 0.1), fill_color=GREY_B, fill_opacity=0.9, stroke_width=0)
    rb = Rectangle(width=1.0, height=max(hr, 0.1), fill_color=ACCENT, fill_opacity=0.95, stroke_width=0)
    lb.next_to(base, UP, buff=0).shift(LEFT * 1.1)
    rb.next_to(base, UP, buff=0).shift(RIGHT * 1.1)
    ll = label(l.get("label", "before"), 16).next_to(lb, DOWN, buff=0.12)
    rl = label(r.get("label", "after"), 16).next_to(rb, DOWN, buff=0.12)
    parts = [base, lb, rb, ll, rl]
    beats = [[FadeIn(base), GrowFromEdge(lb, DOWN), FadeIn(ll)], [GrowFromEdge(rb, DOWN), FadeIn(rl)]]
    if l.get("note"):
        n = mono(l["note"], 18, GREY_C).next_to(lb, UP, buff=0.15)
        strike = Line(n.get_left(), n.get_right(), color=ACCENT, stroke_width=3)
        parts += [n, strike]
        beats.append([FadeIn(n), FadeIn(strike)])
    if r.get("note"):
        n = mono(r["note"], 18, GOLD).next_to(rb, UP, buff=0.15)
        parts.append(n)
        beats.append([FadeIn(n)])
    if spec.get("caption"):
        cap = caption(spec["caption"]).next_to(VGroup(*parts), DOWN, buff=0.35)
        parts.append(cap)
        beats.append([FadeIn(cap)])
    return VGroup(*parts).move_to(region), beats


def g_filter(region: Rectangle, spec: dict):
    """Search narrows a grid: {"query": "Frontend", "total": 12, "kept": 4, "empty": false, "caption": "..."}"""
    total = min(int(spec.get("total", 12)), 15)
    kept = int(spec.get("kept", max(total // 3, 1)))
    win = browser(4.6, 4.4)
    bar = search_bar(3.8, spec.get("query", "")).move_to(win[0].get_top() + DOWN * 0.8)
    grid = card_grid(total, cols=3, w=1.0, h=0.6).next_to(bar, DOWN, buff=0.3)
    parts = [win, bar[0], bar[1], grid, bar[2]]
    beats = [[FadeIn(win), FadeIn(bar[0]), FadeIn(bar[1]), FadeIn(grid, lag_ratio=0.05)], [Write(bar[2])]]
    if spec.get("empty"):
        empty = empty_state(3.4, 1.8).move_to(grid)
        parts.append(empty)
        beats += [[FadeOut(grid)], [FadeIn(empty, shift=UP * 0.1)]]
    else:
        step = max(total // max(kept, 1), 1)
        keep_idx = set(range(0, total, step))
        drop = VGroup(*[grid[i] for i in range(total) if i not in keep_idx])
        keep = [grid[i] for i in keep_idx]
        beats.append([drop.animate.set_opacity(0.08), *[k[0].animate.set_stroke(GOLD) for k in keep]])
        if spec.get("restore"):
            beats.append([FadeOut(bar[2]), drop.animate.set_opacity(1),
                          *[k[0].animate.set_stroke(CARD_EDGE) for k in keep]])
    if spec.get("caption"):
        cap = caption(spec["caption"]).next_to(win, DOWN, buff=0.3)
        parts.append(cap)
        beats.append([FadeIn(cap)])
    return VGroup(*parts).move_to(region), beats


def g_pair(region: Rectangle, spec: dict):
    """Two named boxes and a relationship: {"left": "Playwright", "right": "JobsPage", "arrow": "drives", "caption": "..."}"""
    def block(name):
        return VGroup(VGroup(panel(2.0, 1.4), label(name[:1].upper(), 40, GREY_B, "BOLD")),
                      label(name, 18, WHITE, "BOLD")).arrange(DOWN, buff=0.2)
    left, right = block(spec.get("left", "A")), block(spec.get("right", "B"))
    pair = VGroup(left, right).arrange(RIGHT, buff=0.9)
    arrow = Arrow(left[0].get_right(), right[0].get_left(), color=ACCENT, buff=0.1, stroke_width=3)
    parts = [pair, arrow]
    beats = [[FadeIn(left, shift=UP * 0.2)], [FadeIn(right, shift=UP * 0.2)], [GrowFromEdge(arrow, LEFT)]]
    if spec.get("arrow"):
        tag = caption(spec["arrow"]).next_to(arrow, UP, buff=0.1)
        parts.append(tag)
        beats[-1].append(FadeIn(tag))
    if spec.get("caption"):
        cap = caption(spec["caption"]).next_to(pair, DOWN, buff=0.5)
        parts.append(cap)
        beats.append([FadeIn(cap)])
    return VGroup(*parts).move_to(region), beats


def g_checklist(region: Rectangle, spec: dict):
    """Items ticked one by one: {"items": ["...", "..."], "caption": "..."}"""
    rows = VGroup()
    for text in spec.get("items", [])[:6]:
        tick = Text("✓", font=FONT, font_size=22, color=GOLD, weight="BOLD")
        rows.add(VGroup(tick, label(text, 19, WHITE)).arrange(RIGHT, buff=0.25))
    rows.arrange(DOWN, aligned_edge=LEFT, buff=0.35)
    parts = [rows]
    beats = _rows_reveal(list(rows), shift=RIGHT * 0.2)
    if spec.get("caption"):
        cap = caption(spec["caption"]).next_to(rows, DOWN, buff=0.45)
        parts.append(cap)
        beats.append([FadeIn(cap)])
    return VGroup(*parts).move_to(region), beats


def g_callout(region: Rectangle, spec: dict):
    """A highlighted token and what it means: {"code": "NO_MATCH_TERM", "text": "a term that ...", "bad": "== 10"}"""
    parts, beats = [], []
    chip_m = chip(spec.get("code", ""))
    parts.append(chip_m)
    beats.append([FadeIn(chip_m, scale=0.8)])
    if spec.get("text"):
        body = label(spec["text"], 19, WHITE)
        if body.width > 4.6:
            body.scale_to_fit_width(4.6)
        box = panel(body.width + 0.5, body.height + 0.45)
        card = VGroup(box, body.move_to(box)).next_to(chip_m, DOWN, buff=0.45)
        parts.append(card)
        beats.append([FadeIn(card, shift=UP * 0.15)])
    if spec.get("bad"):
        bad = mono(spec["bad"], 18, GREY_C).next_to(VGroup(*parts), DOWN, buff=0.45)
        strike = Line(bad.get_left(), bad.get_right(), color=ACCENT, stroke_width=3)
        parts += [bad, strike]
        beats.append([FadeIn(bad), FadeIn(strike)])
    return VGroup(*parts).move_to(region), beats


GENERIC = {
    "flow": g_flow,
    "compare": g_compare,
    "filter": g_filter,
    "pair": g_pair,
    "checklist": g_checklist,
    "callout": g_callout,
}
