#!/usr/bin/env python3
"""token-usage.py — what coding-agent subscription use would cost at API prices.

WHY THIS EXISTS
---------------
A flat subscription hides the per-token price, which makes it impossible to
judge whether paying by the token would be cheaper, dearer, or simply
different. Both clients already record what each request used, locally and
without any telemetry switched on:

  * Claude Code writes a transcript per session under ~/.claude/projects/,
    and every assistant message in it carries the model and its input,
    output, cache-read and cache-write token counts.
  * Codex writes a rollout per session under ~/.codex/sessions/, with
    running token totals and the plan's rate-limit windows.

This reads both, prices every token type at its own list rate, and writes a
JSON summary and, optionally, a self-contained HTML report (page.html beside
this file). It is a workstation script, not a role: the data lives on the
machine that ran the agents, and nothing here touches a host (#1334).

WHAT IT GETS RIGHT THAT A NAIVE SUM DOES NOT
  * Claude Code repeats an assistant message's line once per content block,
    so about half the lines are duplicates. Records are deduplicated on
    (message.id, requestId).
  * Cache reads dominate agent sessions and cost a fraction of fresh input,
    so a raw token total overstates the cost several times over. Each type
    is priced separately: fresh input, 5-minute and 1-hour cache writes,
    cache reads, output, and web searches.
  * Subagent transcripts live in <session>/subagents/ and are counted with
    the session that started them.

LIMITS
  * Claude Code deletes transcripts after `cleanupPeriodDays` (30 by
    default), so history before that is gone unless the setting was raised.
  * Subscription usage limits are not in Claude Code's transcripts.
  * Codex's image generation is billed separately by OpenAI and does not
    appear in its token counts.
  * Prices change. PRICES_FETCHED says when the tables below were checked;
    an unknown model is reported and left out rather than guessed at.

USAGE
  scripts/token-usage/token-usage.py                      # summary only
  scripts/token-usage/token-usage.py --json out.json --html out.html

EXIT CODES
  0  report written
  1  no Claude Code usage found
"""

import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

PRICES_FETCHED = "2026-09-29"

# $ per million tokens: fresh input, 5-minute cache write, 1-hour cache
# write, cache read, output. Source: platform.claude.com/docs/en/about-claude/pricing
CLAUDE_PRICES = {
    "claude-fable-5-1": (10, 12.5, 20, 0.25, 50),
    "claude-fable-5": (10, 12.5, 20, 1.00, 50),
    "claude-opus-5-5": (4, 5, 8, 0.20, 20),
    "claude-opus-5": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-8": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-7": (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-6": (5, 6.25, 10, 0.50, 25),
    "claude-sonnet-5-5": (2, 2.5, 4, 0.20, 10),
    "claude-sonnet-5": (2, 2.5, 4, 0.20, 10),
    "claude-sonnet-4-6": (3, 3.75, 6, 0.30, 15),
    "claude-haiku-4-5": (1, 1.25, 2, 0.10, 5),
}
WEB_SEARCH_EACH = 0.01

# $ per million tokens: input, cached input, output.
# Source: developers.openai.com/api/docs/pricing
CODEX_PRICES = {
    "gpt-5.6-sol": (4.00, 0.40, 20.00),
    "gpt-5.6-terra": (2.00, 0.20, 12.00),
    "gpt-5.6-luna": (0.20, 0.02, 1.20),
}

# The report stacks at most four models by name; the rest fold into "Other"
# so a new model never forces a fifth colour the palette was not checked for.
NAMED_SERIES = 4


def price_key(model, table):
    """Longest matching prefix, so claude-opus-5-5 never prices as claude-opus-5."""
    for key in sorted(table, key=len, reverse=True):
        if model.startswith(key):
            return key
    return None


def label(model):
    """claude-opus-5-5 -> Opus 5.5."""
    name = re.sub(r"^claude-", "", model)
    parts = name.split("-")
    return parts[0].capitalize() + " " + ".".join(parts[1:])


def project_of(cwd):
    if not cwd:
        return "?"
    cwd = re.sub(r"/\.claude/worktrees/[^/]+.*$", "", cwd)
    return os.path.basename(cwd.rstrip("/")) or cwd


def local_tz():
    """The machine's named zone, so days stay right across a DST change; a fixed offset otherwise."""
    name = os.environ.get("TZ") or ""
    if not name:
        link = os.path.realpath("/etc/localtime")
        name = link.split("zoneinfo/", 1)[1] if "zoneinfo/" in link else ""
    try:
        return ZoneInfo(name) if name else dt.datetime.now().astimezone().tzinfo
    except (ZoneInfoNotFoundError, ValueError):
        return dt.datetime.now().astimezone().tzinfo


def local_day(timestamp, tz):
    return dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone(tz).date().isoformat()


def records(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def read_claude(root, tz, unknown):
    seen, calls, ai_titles, custom_titles = set(), [], {}, {}
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        is_sub = f"{os.sep}subagents{os.sep}" in path
        session = Path(path).parent.parent.name if is_sub else Path(path).stem
        for rec in records(path):
            kind = rec.get("type")
            if kind == "ai-title":
                ai_titles[rec.get("sessionId")] = rec.get("aiTitle")
                continue
            if kind == "custom-title":
                custom_titles[rec.get("sessionId")] = rec.get("customTitle")
                continue
            msg = rec.get("message")
            if kind != "assistant" or not isinstance(msg, dict) or "usage" not in msg:
                continue
            key = (msg.get("id"), rec.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            model = msg.get("model") or "?"
            if model == "<synthetic>":
                continue
            pk = price_key(model, CLAUDE_PRICES)
            if not pk:
                unknown[model] += 1
                continue
            p, u = CLAUDE_PRICES[pk], msg["usage"]
            cc = u.get("cache_creation") or {}
            w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
            if w5 is None and w1 is None:  # older records: all writes at the 5-minute rate
                w5, w1 = u.get("cache_creation_input_tokens", 0), 0
            tok = {
                "input": u.get("input_tokens", 0) or 0,
                "write5": w5 or 0,
                "write1h": w1 or 0,
                "read": u.get("cache_read_input_tokens", 0) or 0,
                "output": u.get("output_tokens", 0) or 0,
            }
            cost = {
                "input": tok["input"] * p[0] / 1e6,
                "write5": tok["write5"] * p[1] / 1e6,
                "write1h": tok["write1h"] * p[2] / 1e6,
                "read": tok["read"] * p[3] / 1e6,
                "output": tok["output"] * p[4] / 1e6,
                "web": ((u.get("server_tool_use") or {}).get("web_search_requests", 0) or 0) * WEB_SEARCH_EACH,
            }
            calls.append({
                "model": label(pk), "sub": is_sub, "session": session, "cwd": rec.get("cwd"),
                "day": local_day(rec["timestamp"], tz),
                "context": tok["input"] + tok["write5"] + tok["write1h"] + tok["read"],
                "tok": tok, "cost": cost, "total": sum(cost.values()),
            })
    titles = {**custom_titles, **ai_titles}  # the generated title describes the content; prefer it
    return calls, titles


def read_codex(root, tz, unknown):
    out = {"runs": 0, "sources": collections.Counter(), "plan": None, "peak5h": 0, "peakWeek": 0,
           "days": set(), "input": 0, "cached": 0, "output": 0, "cost": 0.0}
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        model, previous = None, None
        out["runs"] += 1
        for rec in records(path):
            kind, payload = rec.get("type"), rec.get("payload") or {}
            if kind == "session_meta":
                out["sources"][str(payload.get("source") or "?")] += 1
                if payload.get("timestamp"):
                    out["days"].add(local_day(payload["timestamp"], tz))
            elif kind == "turn_context":
                model = payload.get("model") or model
            elif kind == "event_msg" and payload.get("type") == "token_count":
                limits = payload.get("rate_limits") or {}
                out["plan"] = limits.get("plan_type") or out["plan"]
                for window in ("primary", "secondary"):
                    w = limits.get(window) or {}
                    if w.get("window_minutes") == 300:
                        out["peak5h"] = max(out["peak5h"], w.get("used_percent") or 0)
                    elif w.get("window_minutes") == 10080:
                        out["peakWeek"] = max(out["peakWeek"], w.get("used_percent") or 0)
                total = (payload.get("info") or {}).get("total_token_usage")
                if not total:
                    continue
                # Totals are running sums; price the step since the last one
                # at the model in force now, so a mid-session switch is split.
                delta = {k: total.get(k, 0) - (previous or {}).get(k, 0) for k in ("input_tokens", "cached_input_tokens", "output_tokens")}
                if min(delta.values()) < 0:  # the running total restarted
                    delta = {k: total.get(k, 0) for k in delta}
                previous = total
                out["input"] += delta["input_tokens"]
                out["cached"] += delta["cached_input_tokens"]
                out["output"] += delta["output_tokens"]
                pk = price_key(model or "", CODEX_PRICES)
                if not pk:
                    unknown[f"codex:{model}"] += 1
                    continue
                p = CODEX_PRICES[pk]
                fresh = delta["input_tokens"] - delta["cached_input_tokens"]  # cached is a subset of input
                out["cost"] += fresh * p[0] / 1e6 + delta["cached_input_tokens"] * p[1] / 1e6 + delta["output_tokens"] * p[2] / 1e6
    out["activeDays"] = len(out.pop("days"))
    out["sources"] = dict(out["sources"])
    out["cost"] = round(out["cost"], 2)
    return out


def summarise(calls, titles, codex, tz):
    days = sorted({c["day"] for c in calls})
    first, last = dt.date.fromisoformat(days[0]), dt.date.fromisoformat(days[-1])
    calendar = [(first + dt.timedelta(n)).isoformat() for n in range((last - first).days + 1)]

    by_model = collections.Counter()
    for c in calls:
        by_model[c["model"]] += c["total"]
    named = [m for m, _ in by_model.most_common(NAMED_SERIES)]
    series = named + (["Other"] if len(by_model) > len(named) else [])
    other_models = sorted(set(by_model) - set(named))

    daily = {d: dict.fromkeys(series, 0.0) for d in calendar}
    tok, cost = collections.Counter(), collections.Counter()
    sessions = collections.defaultdict(lambda: {"cost": 0.0, "calls": 0, "project": None, "day": None,
                                                "models": collections.Counter(), "sub": 0.0})
    for c in calls:
        s = c["model"] if c["model"] in named else "Other"
        daily[c["day"]][s] += c["total"]
        tok.update(c["tok"])
        cost.update(c["cost"])
        rec = sessions[c["session"]]
        rec["cost"] += c["total"]
        rec["calls"] += 1
        rec["models"][s] += c["total"]
        if c["sub"]:
            rec["sub"] += c["total"]
        elif rec["project"] is None:
            rec["project"] = project_of(c["cwd"])
        rec["day"] = min(rec["day"] or c["day"], c["day"])

    projects = collections.Counter()
    for rec in sessions.values():
        projects[rec["project"] or "?"] += rec["cost"]
    total = sum(c["total"] for c in calls)
    context = sorted(c["context"] for c in calls)
    bin_size, bins = 50_000, 14
    hist = [0] * bins
    for x in context:
        hist[min(x // bin_size, bins - 1)] += 1
    per_session = sorted(r["cost"] for r in sessions.values())
    per_day = [sum(v.values()) for v in daily.values() if sum(v.values()) > 0]
    top = sorted(sessions.items(), key=lambda kv: -kv[1]["cost"])[:12]

    return {
        "generated": dt.date.today().isoformat(), "pricesFetched": PRICES_FETCHED, "timezone": str(tz),
        "period": [days[0], days[-1]], "activeDays": len(days), "calls": len(calls), "sessions": len(sessions),
        "total": total, "medianSession": statistics.median(per_session), "meanSession": statistics.mean(per_session),
        "maxSession": max(per_session), "medianDay": statistics.median(per_day), "maxDay": max(per_day),
        "subagentCost": sum(r["sub"] for r in sessions.values()),
        "models": series, "otherModels": other_models,
        "daily": [{"day": d, **{m: round(v[m], 2) for m in series}} for d, v in daily.items()],
        "byModel": {m: round(sum(v[m] for v in daily.values()), 2) for m in series},
        "tokens": {k: tok[k] for k in ("read", "write1h", "write5", "output", "input")},
        "costByType": {k: round(cost[k], 2) for k in ("read", "write1h", "write5", "output", "input")},
        "ctx": {"median": statistics.median(context), "p90": context[int(len(context) * 0.9)],
                "over200": sum(x > 200_000 for x in context) / len(context), "binSize": bin_size, "hist": hist},
        "projects": [{"name": k, "cost": round(v, 2)} for k, v in projects.most_common()],
        "top": [{"day": r["day"], "title": titles.get(k) or "(untitled)", "project": r["project"] or "?",
                 "calls": r["calls"], "cost": round(r["cost"], 2), "model": r["models"].most_common(1)[0][0]}
                for k, r in top],
        "codex": codex,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--claude-dir", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--codex-dir", default=os.path.expanduser("~/.codex/sessions"))
    ap.add_argument("--json", metavar="PATH", help="write the summary as JSON")
    ap.add_argument("--html", metavar="PATH", help="write the self-contained HTML report")
    args = ap.parse_args()

    tz = local_tz()
    unknown = collections.Counter()
    calls, titles = read_claude(args.claude_dir, tz, unknown)
    if not calls:
        print(f"no Claude Code usage found under {args.claude_dir}", file=sys.stderr)
        return 1
    codex = read_codex(args.codex_dir, tz, unknown)
    data = summarise(calls, titles, codex, tz)

    if args.json:
        Path(args.json).write_text(json.dumps(data, indent=1))
    if args.html:
        template = (Path(__file__).parent / "page.html").read_text()
        Path(args.html).write_text(template.replace("__DATA__", json.dumps(data, separators=(",", ":"))))

    t = data["costByType"]
    print(f"{data['period'][0]} .. {data['period'][1]}: {data['sessions']} sessions, {data['calls']:,} calls")
    print(f"Claude Code at API prices: ${data['total']:,.2f}  (cache reads {t['read'] / data['total']:.0%}, "
          f"cache writes {(t['write1h'] + t['write5']) / data['total']:.0%}, output {t['output'] / data['total']:.0%})")
    print(f"median session ${data['medianSession']:.2f}, median context {data['ctx']['median']:,.0f} tokens")
    for m in data["models"]:
        print(f"  {m:12} ${data['byModel'][m]:>10,.2f}")
    print(f"Codex: {codex['runs']} runs, ${codex['cost']:,.2f} at API prices (images not included)")
    if unknown:
        print(f"unpriced and left out, add them to the price tables: {dict(unknown)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
