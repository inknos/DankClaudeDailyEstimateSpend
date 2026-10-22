#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 nsella
"""Summarise Claude Code token usage from ~/.claude/projects logs as JSON.

Costs are estimates at Anthropic API list prices; on a subscription they are an
"API-equivalent" figure, not a bill. Per-file results are cached so repeated
runs only re-read logs that changed.
"""
import json
import os
import sys
import time
from datetime import datetime, timedelta

ROOTS = [os.path.expanduser(p) for p in os.environ.get(
    "CLAUDE_USAGE_ROOTS", "~/.claude/projects:~/.config/claude/projects").split(":")]
CACHE = os.path.expanduser("~/.cache/dms-claude-usage/cache.json")
CACHE_VERSION = 2

# $/MTok: input, output, cache read. Cache writes are 1.25x (5m) / 2x (1h) input.
# Matched by prefix, most specific first. Source: Anthropic pricing as of 2026-10.
PRICES = [
    ("claude-fable-5-1", 10.0, 50.0, 0.25),
    ("claude-mythos-5-1", 10.0, 50.0, 0.25),
    ("claude-fable-5", 10.0, 50.0, 1.00),
    ("claude-mythos-5", 10.0, 50.0, 1.00),
    ("claude-opus-5-5", 4.0, 20.0, 0.20),
    ("claude-opus-5", 5.0, 25.0, 0.50),
    ("claude-opus-4-1", 15.0, 75.0, 1.50),
    ("claude-opus-4-0", 15.0, 75.0, 1.50),
    ("claude-opus-4-2", 15.0, 75.0, 1.50),
    ("claude-opus-4", 5.0, 25.0, 0.50),
    ("claude-sonnet-5-5", 2.0, 10.0, 0.20),
    ("claude-sonnet-5", 2.0, 10.0, 0.20),
    ("claude-sonnet-4", 3.0, 15.0, 0.30),
    ("claude-3-7-sonnet", 3.0, 15.0, 0.30),
    ("claude-haiku-5-5", 0.10, 0.50, 0.01),
    ("claude-haiku-4", 1.0, 5.0, 0.10),
    ("claude-3-5-haiku", 0.8, 4.0, 0.08),
]
HAIKU55_LONG = 100_000  # prompts above this bill at 5x on Haiku 5.5
WEB_SEARCH_USD = 0.01


def price_for(model):
    for prefix, i, o, r in PRICES:
        if model.startswith(prefix):
            return i, o, r
    return None


def cost_of(e):
    model, inp, out, cw5, cw1, cr, web, fast = e[1:9]
    p = price_for(model)
    if p is None:
        return 0.0, False
    i, o, r = p
    mult = 2.0 if fast else 1.0
    if model.startswith("claude-haiku-5-5") and inp + cw5 + cw1 + cr > HAIKU55_LONG:
        mult *= 5.0
    usd = (inp * i + out * o + cw5 * i * 1.25 + cw1 * i * 2.0 + cr * r) / 1e6 * mult
    return usd + web * WEB_SEARCH_USD, True


def parse_file(path):
    """Return {dedup_key: [ts, model, in, out, cw5, cw1, cr, web, fast, project]}."""
    entries = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            m = d.get("message")
            if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                continue
            model = m.get("model") or ""
            if not model or model.startswith("<"):
                continue
            u = m["usage"]
            cc = u.get("cache_creation") or {}
            cw_total = u.get("cache_creation_input_tokens") or 0
            cw1 = cc.get("ephemeral_1h_input_tokens") or 0
            cw5 = cc.get("ephemeral_5m_input_tokens", cw_total - cw1) or 0
            web = (u.get("server_tool_use") or {}).get("web_search_requests") or 0
            key = "%s:%s" % (m.get("id", ""), d.get("requestId", ""))
            if key == ":":
                key = d.get("uuid") or str(len(entries))
            entries[key] = [
                d.get("timestamp", ""), model,
                u.get("input_tokens") or 0, u.get("output_tokens") or 0,
                cw5, cw1, u.get("cache_read_input_tokens") or 0, web,
                u.get("speed") == "fast",
                os.path.basename((d.get("cwd") or "").rstrip("/")) or "?",
            ]
    return entries


def load_entries():
    try:
        with open(CACHE) as f:
            cache = json.load(f)
        if cache.get("v") != CACHE_VERSION:
            cache = {}
    except (OSError, ValueError):
        cache = {}
    files = cache.get("files", {})
    seen, changed = set(), False
    for root in ROOTS:
        for dirpath, _, names in os.walk(root):
            for n in names:
                if not n.endswith(".jsonl"):
                    continue
                p = os.path.join(dirpath, n)
                try:
                    st = os.stat(p)
                except OSError:
                    continue
                seen.add(p)
                sig = [st.st_mtime, st.st_size]
                if files.get(p, {}).get("sig") != sig:
                    try:
                        files[p] = {"sig": sig, "entries": parse_file(p)}
                        changed = True
                    except OSError:
                        pass
    for p in list(files):
        if p not in seen:
            del files[p]
            changed = True
    if changed:
        # Several bars run this at once: per-process tmp file, and a lost write only costs a re-parse
        tmp = "%s.%d.tmp" % (CACHE, os.getpid())
        try:
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            with open(tmp, "w") as f:
                json.dump({"v": CACHE_VERSION, "files": files}, f)
            os.replace(tmp, CACHE)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    merged = {}
    for fdata in files.values():
        merged.update(fdata["entries"])
    return merged.values()


def main():
    now = datetime.now().astimezone()
    today = now.date()
    month_start = today.replace(day=1)
    window_start = now - timedelta(hours=5)
    days = {(today - timedelta(days=i)).isoformat(): {"cost": 0.0, "tokens": 0} for i in range(13, -1, -1)}

    def bucket():
        return {"cost": 0.0, "tokens": 0, "requests": 0}

    today_b, week_b, month_b, win_b, all_b = bucket(), bucket(), bucket(), bucket(), bucket()
    models, projects, unpriced = {}, {}, set()

    for e in load_entries():
        try:
            ts = datetime.fromisoformat(e[0].replace("Z", "+00:00")).astimezone()
        except ValueError:
            continue
        usd, priced = cost_of(e)
        if not priced:
            unpriced.add(e[1])
        tokens = sum(e[2:7])
        d = ts.date()

        def add(b):
            b["cost"] += usd
            b["tokens"] += tokens
            b["requests"] += 1

        add(all_b)
        if d == today:
            add(today_b)
        if (today - d).days < 7:
            add(week_b)
        if ts >= window_start:
            add(win_b)
        if d.isoformat() in days:
            days[d.isoformat()]["cost"] += usd
            days[d.isoformat()]["tokens"] += tokens
        if d >= month_start:
            add(month_b)
            add(models.setdefault(e[1], bucket()))
            add(projects.setdefault(e[9], bucket()))

    def ranked(dct, limit):
        return [dict(name=k, **v) for k, v in sorted(dct.items(), key=lambda kv: -kv[1]["cost"])[:limit]]

    json.dump({
        "generated": int(time.time()),
        "today": today_b, "week": week_b, "month": month_b, "window5h": win_b, "allTime": all_b,
        "days": [dict(date=k, **v) for k, v in days.items()],
        "models": ranked(models, 6),
        "projects": ranked(projects, 6),
        "unpriced": sorted(unpriced),
    }, sys.stdout)


if __name__ == "__main__":
    main()
