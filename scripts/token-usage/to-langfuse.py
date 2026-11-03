#!/usr/bin/env python3
"""to-langfuse.py — send Codex's and Antigravity's token use to LangFuse.

WHY THIS EXISTS
---------------
Claude Code reaches LangFuse through LangFuse's own plugin. Codex and
Antigravity have nothing that sends usage LangFuse can read, but both record
every model call's token counts on the machine that ran them (#1334):

  * Codex writes a rollout per session under ~/.codex/sessions/, with running
    token totals after each call and the model in force from turn_context.
  * Antigravity keeps a SQLite file per conversation under
    ~/.gemini/antigravity/conversations/. Each row of its gen_metadata table
    is one model call, a protobuf naming the model and carrying its tokens.

This reads both and sends LangFuse one trace per session and one generation
per call, with the model, token counts and API-equivalent cost. It sends
nothing a session said: no prompt, reply, tool call or file content.

HOW IT SENDS
------------
OTLP/JSON to LangFuse's own OpenTelemetry endpoint, with the attributes its
SDK uses (langfuse.observation.*, langfuse.trace.*). Trace and span ids are
derived from the session and call, so a re-run replaces what it sent before
rather than adding to it. A state file records which source files were sent
at which size, and only changed files are sent again.

ANTIGRAVITY'S FIELDS ARE READ, NOT DOCUMENTED
---------------------------------------------
Google publishes no schema for these files. Field 1.4 of a gen_metadata row
is taken to be the usage message: 2 fresh input, 5 cached input, 3 output
with thinking, 9 thinking, 10 visible output. 9 + 10 = 3 in every row read on
2026-11-03, and 2 + 5 grows call by call as a conversation does; nothing
stronger confirms it. The call's time is field 1.9.4.1, in seconds, and the
file's modification time where a row has none. A row this cannot read is
counted and skipped, never guessed at.

USAGE
  scripts/token-usage/to-langfuse.py --dry-run        # what would be sent
  scripts/token-usage/to-langfuse.py                  # send what changed
  scripts/token-usage/to-langfuse.py --all            # send everything again

Keys come from LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_BASE_URL,
or from ~/.config/agent-usage/langfuse.env (KEY=value lines, mode 600).

EXIT CODES
  0  sent, or nothing to send
  1  LangFuse refused a batch, or the keys are missing
"""

import argparse
import base64
import collections
import datetime as dt
import glob
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("token_usage", HERE / "token-usage.py")
token_usage = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(token_usage)
CODEX_PRICES, price_key, project_of = token_usage.CODEX_PRICES, token_usage.price_key, token_usage.project_of

GEMINI_PRICES_FETCHED = "2026-11-03"
# $ per million tokens: fresh input, cached input, output (thinking included),
# each from the date it applies. Source: aistudio.google.com/docs/pricing,
# paid tier, standard. Cache storage is billed by the hour and not counted.
GEMINI_PRICES = {
    "gemini-3.6-flash": [("2026-01-01", (0.75, 0.075, 3.75)), ("2027-01-01", (1.50, 0.15, 7.50))],
    "gemini-3.8-flash": [("2026-01-01", (0.75, 0.075, 3.75)), ("2027-01-01", (1.50, 0.15, 7.50))],
}

CONFIG = Path("~/.config/agent-usage/langfuse.env").expanduser()
STATE = Path("~/.local/state/agent-usage/sent.json").expanduser()
BATCH = 200


def ids(*parts, size):
    return hashlib.sha256(":".join(parts).encode()).hexdigest()[:size]


def gemini_price(model, day):
    key = price_key(model, GEMINI_PRICES)
    if not key:
        return None
    current = None
    for since, prices in GEMINI_PRICES[key]:
        if day >= since:
            current = prices
    return key, current


def cost(prices, fresh, cached, output):
    c = {"input": fresh * prices[0] / 1e6, "cache_read_input_tokens": cached * prices[1] / 1e6,
         "output": output * prices[2] / 1e6}
    c["total"] = sum(c.values())
    return c


def usage(fresh, cached, output):
    return {"input": fresh, "cache_read_input_tokens": cached, "output": output,
            "total": fresh + cached + output}


# ---- Codex ----

def read_codex(path, unknown):
    """One session: (id, cwd, calls). A call is the step between two running totals."""
    session, cwd, model, previous, calls = Path(path).stem, None, None, None, []
    for rec in token_usage.records(path):
        kind, payload = rec.get("type"), rec.get("payload") or {}
        if kind == "session_meta":
            session = payload.get("id") or session
            cwd = payload.get("cwd") or cwd
        elif kind == "turn_context":
            model = payload.get("model") or model
            cwd = payload.get("cwd") or cwd
        elif kind == "event_msg" and payload.get("type") == "token_count":
            total = (payload.get("info") or {}).get("total_token_usage")
            if not total:
                continue
            keys = ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens")
            delta = {k: total.get(k, 0) - (previous or {}).get(k, 0) for k in keys}
            if min(delta.values()) < 0:  # the running total restarted
                delta = {k: total.get(k, 0) for k in keys}
            previous = total
            if not any(delta.values()):  # a rate-limit update, not a call
                continue
            pk = price_key(model or "", CODEX_PRICES)
            if not pk:
                unknown[f"codex:{model}"] += 1
                continue
            fresh = delta["input_tokens"] - delta["cached_input_tokens"]  # cached is a subset of input
            calls.append({
                "at": rec["timestamp"], "model": pk,
                "usage": usage(fresh, delta["cached_input_tokens"], delta["output_tokens"]),
                "cost": cost(CODEX_PRICES[pk], fresh, delta["cached_input_tokens"], delta["output_tokens"]),
                "reasoning": delta["reasoning_output_tokens"],
            })
    return session, cwd, calls


# ---- Antigravity ----

def _varint(b, i):
    shift = value = 0
    while True:
        c = b[i]
        i += 1
        value |= (c & 0x7F) << shift
        shift += 7
        if c < 0x80:
            return value, i


def _fields(b, path="", depth=0):
    """Every varint and string in a protobuf, by dotted field path; None if b is not one."""
    out, i = [], 0
    try:
        while i < len(b):
            key, i = _varint(b, i)
            number, wire = key >> 3, key & 7
            if number == 0:
                return None
            if wire == 0:
                value, i = _varint(b, i)
                out.append((f"{path}{number}", value))
            elif wire == 2:
                n, i = _varint(b, i)
                sub = b[i:i + n]
                i += n
                nested = _fields(sub, f"{path}{number}.", depth + 1) if n and depth < 6 else None
                out.extend(nested if nested is not None else [(f"{path}{number}", sub)])
            elif wire == 1:
                i += 8
            elif wire == 5:
                i += 4
            else:
                return None
    except IndexError:
        return None
    return out


PROJECT_PATH = re.compile(rb"/(?:home|Users)/[^/\s\"']+/Projects/([A-Za-z0-9._-]+)")


def read_antigravity(path, unknown):
    """One conversation: (id, project, calls)."""
    session = Path(path).stem
    fallback = dt.datetime.fromtimestamp(os.stat(path).st_mtime, dt.timezone.utc)
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    # The project is the repository its steps name most often. Only the name is kept.
    projects = collections.Counter()
    for (blob,) in db.execute("select step_payload from steps"):
        if isinstance(blob, (bytes, str)):
            projects.update(m.decode() for m in PROJECT_PATH.findall(blob if isinstance(blob, bytes) else blob.encode()))
    calls = []
    for idx, data in db.execute("select idx, data from gen_metadata order by idx"):
        fields = _fields(bytes(data)) or []
        u = {p: v for p, v in fields if p.startswith("1.4.") and isinstance(v, int)}
        model = next((m.group(0).decode() for _, v in fields if isinstance(v, bytes)
                      for m in [re.fullmatch(rb"gemini-[0-9.]+-[a-z]+", v)] if m), None)
        seconds = next((v for p, v in fields if p == "1.9.4.1" and isinstance(v, int)), None)
        if "1.4.2" not in u or "1.4.3" not in u or not model:
            unknown["antigravity:unreadable row"] += 1
            continue
        at = dt.datetime.fromtimestamp(seconds, dt.timezone.utc) if seconds else fallback
        priced = gemini_price(model, at.date().isoformat())
        if not priced or not priced[1]:
            unknown[f"antigravity:{model}"] += 1
            continue
        fresh, cached, output = u["1.4.2"], u.get("1.4.5", 0), u["1.4.3"]
        calls.append({
            "at": at.isoformat(), "model": priced[0], "usage": usage(fresh, cached, output),
            "cost": cost(priced[1], fresh, cached, output), "reasoning": u.get("1.4.9", 0),
            "estimated_time": seconds is None,
        })
    db.close()
    return session, (projects.most_common(1)[0][0] if projects else None), calls


# ---- OTLP ----

def _attr(key, value):
    if isinstance(value, bool):
        v = {"boolValue": value}
    elif isinstance(value, int):
        v = {"intValue": str(value)}
    elif isinstance(value, list):
        v = {"arrayValue": {"values": [{"stringValue": str(x)} for x in value]}}
    else:
        v = {"stringValue": str(value)}
    return {"key": key, "value": v}


def _ns(iso):
    t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return str(int(t.timestamp()) * 10**9 + t.microsecond * 1000)


def spans_for(agent, session, project, cwd, calls):
    """A root span for the session and a generation per call, all under one trace."""
    trace = ids(agent, session, size=32)
    root = ids(agent, session, "root", size=16)
    meta = {"agent": agent, "project": project or "?"}
    if cwd:
        meta["cwd"] = cwd
    trace_attrs = [
        _attr("langfuse.trace.name", f"{agent} session"),
        _attr("session.id", session),
        _attr("langfuse.trace.tags", [agent]),
        *[_attr(f"langfuse.trace.metadata.{k}", v) for k, v in meta.items()],
    ]
    spans = [{
        "traceId": trace, "spanId": root, "name": f"{agent} session", "kind": 1,
        "startTimeUnixNano": _ns(calls[0]["at"]), "endTimeUnixNano": _ns(calls[-1]["at"]),
        "attributes": [_attr("langfuse.observation.type", "span"), _attr("langfuse.internal.as_root", True),
                       *trace_attrs],
    }]
    for n, call in enumerate(calls):
        attrs = [
            _attr("langfuse.observation.type", "generation"),
            _attr("langfuse.observation.model.name", call["model"]),
            _attr("langfuse.observation.usage_details", json.dumps(call["usage"])),
            _attr("langfuse.observation.cost_details", json.dumps(call["cost"])),
            _attr("langfuse.observation.metadata.reasoning_tokens", call["reasoning"]),
            *trace_attrs,
        ]
        if call.get("estimated_time"):
            attrs.append(_attr("langfuse.observation.metadata.time_estimated", True))
        spans.append({
            "traceId": trace, "spanId": ids(agent, session, str(n), size=16), "parentSpanId": root,
            "name": f"{agent} call", "kind": 1,
            "startTimeUnixNano": _ns(call["at"]), "endTimeUnixNano": _ns(call["at"]),
            "attributes": attrs,
        })
    return spans


def payload(spans):
    return {"resourceSpans": [{
        "resource": {"attributes": [_attr("service.name", "agent-usage")]},
        "scopeSpans": [{"scope": {"name": "bezaforge.agent-usage", "version": "1"}, "spans": spans}],
    }]}


def credentials():
    env = dict(os.environ)
    if CONFIG.exists():
        if CONFIG.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            sys.exit(f"{CONFIG} is readable by others; chmod 600 it first")
        for line in CONFIG.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip().strip('"'))
    missing = [k for k in ("LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_BASE_URL") if not env.get(k)]
    if missing:
        print(f"missing {', '.join(missing)}: set them, or write them to {CONFIG}", file=sys.stderr)
        sys.exit(1)
    return env["LANGFUSE_BASE_URL"].rstrip("/"), env["LANGFUSE_PUBLIC_KEY"], env["LANGFUSE_SECRET_KEY"]


def send(base, public, secret, spans):
    auth = base64.b64encode(f"{public}:{secret}".encode()).decode()
    req = urllib.request.Request(
        f"{base}/api/public/otel/v1/traces", data=json.dumps(payload(spans)).encode(), method="POST",
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json",
                 "x-langfuse-ingestion-version": "4"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}"
    except urllib.error.URLError as e:
        return False, str(e.reason)
    partial = json.loads(body or "{}").get("partialSuccess") or {}
    if partial.get("rejectedSpans"):
        return False, f"{partial['rejectedSpans']} spans rejected: {partial.get('errorMessage', '')[:300]}"
    return True, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--codex-dir", default=os.path.expanduser("~/.codex/sessions"))
    ap.add_argument("--antigravity-dir", default=os.path.expanduser("~/.gemini/antigravity/conversations"))
    ap.add_argument("--dry-run", action="store_true", help="report what would be sent, send nothing")
    ap.add_argument("--all", action="store_true", help="send every session, not only changed files")
    ap.add_argument("--show-spans", type=int, default=0, metavar="N", help="with --dry-run, print the first N spans")
    args = ap.parse_args()

    state = json.loads(STATE.read_text()) if STATE.exists() and not args.all else {}
    sources = [("codex", p) for p in glob.glob(os.path.join(args.codex_dir, "**", "*.jsonl"), recursive=True)]
    sources += [("antigravity", p) for p in glob.glob(os.path.join(args.antigravity_dir, "*.db"))]

    unknown, summary, pending = collections.Counter(), collections.defaultdict(lambda: [0, 0, 0.0]), []
    for agent, path in sorted(sources):
        st = os.stat(path)
        mark = [st.st_mtime_ns, st.st_size]
        if state.get(path) == mark:
            continue
        if agent == "codex":
            session, cwd, calls = read_codex(path, unknown)
            project = project_of(cwd) if cwd else None
        else:
            session, project, calls = read_antigravity(path, unknown)
            cwd = None
        if calls:
            pending.append((path, mark, spans_for(agent, session, project, cwd, calls)))
        else:
            state[path] = mark
        for c in calls:
            s = summary[(agent, c["model"])]
            s[0] += 1
            s[1] += c["usage"]["total"]
            s[2] += c["cost"]["total"]

    for (agent, model), (n, tokens, dollars) in sorted(summary.items()):
        print(f"{agent:12} {model:18} {n:6} calls {tokens:>14,} tokens  ${dollars:,.2f}")
    print(f"{len(pending)} session(s) to send, {sum(len(s) for _, _, s in pending)} spans")
    for what, n in unknown.items():
        print(f"skipped {n}: {what}", file=sys.stderr)

    if args.dry_run:
        shown = [s for _, _, spans in pending for s in spans][:args.show_spans]
        for s in shown:
            print(json.dumps(s, indent=1))
        return 0

    base, public, secret = credentials()
    failed = 0
    for path, mark, spans in pending:
        for i in range(0, len(spans), BATCH):
            ok, why = send(base, public, secret, spans[i:i + BATCH])
            if not ok:
                print(f"refused {path}: {why}", file=sys.stderr)
                failed += 1
                break
        else:
            state[path] = mark
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
