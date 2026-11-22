#!/usr/bin/env python3
"""Alert quality review: how often each alert fired, and for how long.

Reads Prometheus's ALERTS series (retention is 35 days) and prints a
Markdown table for docs/monitoring/alert-reviews/. Whether each alert was
actionable is a human judgement; the table leaves that column for the
reviewer (see docs/monitoring/alert-review.md).

Usage: scripts/alerting/alert_review.py [--days 14] [--prometheus URL]
"""

import argparse
import json
import time
import urllib.parse
import urllib.request

STEP = 60  # seconds; ALERTS is evaluated every 30 s


def episodes(timestamps, step=STEP):
    """Split sorted sample timestamps into (start, end) firing episodes.

    A gap longer than two steps starts a new episode, so one missed
    evaluation does not double-count an alert.
    """
    result = []
    for ts in timestamps:
        if result and ts - result[-1][1] <= 2 * step:
            result[-1][1] = ts
        else:
            result.append([ts, ts])
    return [(start, end + step) for start, end in result]


def query_range(prometheus, expr, start, end, step):
    """query_range in chunks (Prometheus caps a query at 11,000 points)."""
    series = {}
    chunk = step * 10_000
    t = start
    while t < end:
        params = urllib.parse.urlencode(
            {"query": expr, "start": t, "end": min(t + chunk, end), "step": step}
        )
        with urllib.request.urlopen(f"{prometheus}/api/v1/query_range?{params}", timeout=60) as resp:
            body = json.load(resp)
        for item in body["data"]["result"]:
            key = tuple(sorted(item["metric"].items()))
            series.setdefault(key, []).extend(float(v[0]) for v in item["values"])
        t += chunk
    return series


def summarise(series):
    """Aggregate per (alertname, severity): episodes, total and longest firing time."""
    rows = {}
    for labels, timestamps in series.items():
        labels = dict(labels)
        key = (labels.get("alertname", "?"), labels.get("severity", "none"))
        row = rows.setdefault(key, {"episodes": 0, "seconds": 0.0, "longest": 0.0, "targets": set()})
        for start, end in episodes(sorted(set(timestamps))):
            row["episodes"] += 1
            row["seconds"] += end - start
            row["longest"] = max(row["longest"], end - start)
        target = labels.get("node") or "/".join(
            v for v in (labels.get("namespace"), labels.get("pod") or labels.get("deployment")) if v
        ) or labels.get("instance", "")
        if target:
            row["targets"].add(target)
    return rows


def human(seconds):
    minutes = round(seconds / 60)
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes} min" if hours < 48 else f"{hours // 24} d {hours % 24} h"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=float, default=14)
    parser.add_argument("--prometheus", default="http://127.0.0.1:9090")
    args = parser.parse_args()

    end = int(time.time())
    start = end - int(args.days * 86400)
    rows = summarise(query_range(args.prometheus, 'ALERTS{alertstate="firing"}', start, end, STEP))

    print(f"Window: {time.strftime('%Y-%m-%d %H:%M', time.gmtime(start))} to "
          f"{time.strftime('%Y-%m-%d %H:%M', time.gmtime(end))} UTC ({args.days:g} days)\n")
    if not rows:
        print("No alerts fired in this window.")
        return
    print("| Alert | Severity | Episodes | Total firing | Longest | Targets | Actionable? | Action |")
    print("|---|---|---|---|---|---|---|---|")
    order = sorted(rows.items(), key=lambda kv: (kv[0][1] != "page", -kv[1]["episodes"], kv[0][0]))
    for (name, severity), row in order:
        targets = ", ".join(sorted(row["targets"])[:3]) + (" …" if len(row["targets"]) > 3 else "")
        print(f"| {name} | {severity} | {row['episodes']} | {human(row['seconds'])} | "
              f"{human(row['longest'])} | {targets} | | |")


if __name__ == "__main__":
    main()
