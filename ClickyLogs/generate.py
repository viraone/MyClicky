#!/usr/bin/env python3
"""ClickyLogs report generator.

Reads Clicky's activity log (JSONL) and writes data.js next to index.html.
Runs both manually (with --backfill, which imports old screenshot timestamps
from the Desktop) and from the background LaunchAgent (no --backfill, since
background jobs can't read the Desktop).
"""
import json, os, sys, glob, datetime
from urllib.parse import urlparse

SUPPORT = os.path.expanduser("~/Library/Application Support/MyClicky")
LOG_DIR = os.path.join(SUPPORT, "ClickyLogs")
SITE_DIR = os.path.join(SUPPORT, "ClickyLogsSite")
CAPTURES_DIR = os.path.expanduser("~/Desktop/VIRADETH_RESUME")
BACKFILL = os.path.join(LOG_DIR, "backfill.jsonl")


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except Exception:
        return None


def import_backfill():
    """One-time import of pre-logging captures (qw*.png mtimes) into the log."""
    os.makedirs(LOG_DIR, exist_ok=True)
    already = set()
    if os.path.exists(BACKFILL):
        with open(BACKFILL) as f:
            for line in f:
                try:
                    already.add(json.loads(line).get("file"))
                except Exception:
                    pass
    if not os.path.isdir(CAPTURES_DIR):
        return
    with open(BACKFILL, "a") as f:
        for path in glob.glob(os.path.join(CAPTURES_DIR, "qw*.png")):
            name = os.path.basename(path)
            if name in already:
                continue
            ts = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
            f.write(json.dumps({"type": "capture", "file": name,
                                "ts": ts.isoformat(), "backfill": "1"}) + "\n")


def main():
    if "--backfill" in sys.argv:
        import_backfill()

    now = datetime.datetime.now().astimezone()
    start = (now - datetime.timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)

    events, seen_captures = [], set()
    paths = sorted(glob.glob(os.path.join(LOG_DIR, "events-*.jsonl")))
    if os.path.exists(BACKFILL):
        paths.append(BACKFILL)
    for path in paths:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                ts = parse_ts(e.get("ts", ""))
                if not ts or not (start <= ts <= now):
                    continue
                if e.get("type") == "capture":
                    name = e.get("file")
                    if name in seen_captures:
                        continue  # app-logged wins over backfill duplicate
                    seen_captures.add(name)
                e["_ts"] = ts
                events.append(e)

    events.sort(key=lambda e: e["_ts"])

    ACTION_TYPES = ["ask", "dictate", "capture", "click", "trash"]
    totals = {k: 0 for k in ACTION_TYPES}
    per_day = {}
    for i in range(7):
        d = (start + datetime.timedelta(days=i)).strftime("%Y-%m-%d")
        per_day[d] = {"date": d, **{k: 0 for k in ACTION_TYPES}}
    hourly = [0] * 24
    sites, apps = {}, {}
    active_minutes = 0
    stream = []

    for e in events:
        t = e["type"]
        day = e["_ts"].strftime("%Y-%m-%d")
        if t in totals:
            totals[t] += 1
            if day in per_day:
                per_day[day][t] += 1
        if t == "sample":
            active_minutes += 1
            hourly[e["_ts"].hour] += 1
            app = e.get("app")
            if app:
                apps[app] = apps.get(app, 0) + 1
        else:
            # Sites only count when Clicky was actually used there.
            url = e.get("url")
            if url:
                domain = urlparse(url).netloc.removeprefix("www.")
                if domain:
                    sites[domain] = sites.get(domain, 0) + 1
            entry = {
                "ts": e["_ts"].strftime("%a %b %d · %I:%M %p"),
                "type": t,
                "text": e.get("text") or e.get("file") or "",
            }
            if url:
                entry["url"] = url
            stream.append(entry)

    data = {
        "generatedAt": now.strftime("%a %b %d, %I:%M %p"),
        "rangeStart": start.strftime("%b %d"),
        "rangeEnd": now.strftime("%b %d, %Y"),
        "totals": {**totals, "activeMinutes": active_minutes},
        "perDay": list(per_day.values()),
        "hourly": hourly,
        "topSites": [{"domain": d, "count": c} for d, c in sorted(sites.items(), key=lambda x: -x[1])[:10]],
        "topApps": [{"app": a, "minutes": m} for a, m in sorted(apps.items(), key=lambda x: -x[1])[:10]],
        "events": stream[::-1][:500],
    }

    os.makedirs(SITE_DIR, exist_ok=True)
    out = os.path.join(SITE_DIR, "data.js")
    with open(out, "w") as f:
        f.write("window.CLICKYLOGS = ")
        json.dump(data, f, indent=2)
        f.write(";\n")

    print(f"ClickyLogs: {sum(totals.values())} actions, {active_minutes} active minutes, "
          f"{len(sites)} sites, {len(apps)} apps → {out}")


if __name__ == "__main__":
    main()
