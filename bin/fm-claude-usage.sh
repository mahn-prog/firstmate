#!/usr/bin/env bash
# fm-claude-usage.sh - read-only per-request and per-session token usage of
# Firstmate-launched Claude Code sessions, from Claude Code's own transcripts.
#
# Usage:
#   bin/fm-claude-usage.sh [--projects <dir>] [--since <YYYY-MM-DD>] [--until <YYYY-MM-DD>]
#                          [--role worker|secondmate|all] [--sessions | --json]
#
# Reads every main-thread transcript <projects>/<dir>/<session>.jsonl (default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects) and writes nothing.
# A session counts only when Firstmate launched it: its first user message is
# the operational-input doorbell (bin/fm-operational-input.sh) or an inline
# launch brief. It is a worker when the brief it read first carries the worker
# role contract ("You are a crewmate"), and a secondmate otherwise.
# --since and --until select sessions by their first timestamp (UTC date,
# inclusive), so a before/after comparison splits on the day a launch changed.
#
# A request is one API call, deduplicated by message id because Claude Code
# writes one transcript line per content block. Its context is
# input + cache_creation + cache_read tokens: everything the model was fed for
# that turn, which is what a working-set lever moves. Subagent requests (the
# <session>/subagents/*.jsonl files) are summed into the session total but not
# into the per-request figures. Compactions come from compact_boundary records;
# cost is the last cost-state totalCostUSD, Claude Code's API-price estimate for
# the whole session (blank when the transcript predates that record).
#
# Default output: one summary row per role. --sessions prints one row per
# session; --json prints one JSON object per session for further analysis.
# Exit status: 0 on success, 1 when the transcript root is missing, 2 on a
# malformed --since or --until date.
set -eu

exec python3 -I - "$@" <<'PY'
from __future__ import annotations

import argparse
import calendar
import glob
import json
import os
import statistics
import sys
import time

DOORBELL = "Firstmate operational input waiting"
INLINE_BRIEF = "FIRSTMATE_OP: v1 launch-brief"
WORKER_MARK = "You are a crewmate"


def parse_args() -> argparse.Namespace:
    default = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
    p = argparse.ArgumentParser(prog="fm-claude-usage.sh", description="Token usage of Firstmate-launched Claude sessions (read-only).")
    p.add_argument("--projects", default=default, help="transcript root (default: %(default)s)")
    p.add_argument("--since", help="first session date to include, YYYY-MM-DD (UTC)")
    p.add_argument("--until", help="last session date to include, YYYY-MM-DD (UTC)")
    p.add_argument("--role", choices=["worker", "secondmate", "all"], default="all")
    out = p.add_mutually_exclusive_group()
    out.add_argument("--sessions", action="store_true", help="one row per session")
    out.add_argument("--json", action="store_true", help="one JSON object per session")
    return p.parse_args()


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if isinstance(block.get("text"), str):
                parts.append(block["text"])
            inner = block.get("content")
            if inner is not None and inner is not content:
                parts.append(text_of(inner))
        return "\n".join(parts)
    return ""


def context_of(usage: dict) -> int:
    return sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


def request_contexts(path: str) -> list[tuple[int, int]]:
    """(context, output) per unique API request in one transcript file."""
    seen: dict[str, tuple[int, int]] = {}
    order: list[str] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"usage"' not in line or '"assistant"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant":
                continue
            msg = rec.get("message") or {}
            usage = msg.get("usage")
            if not isinstance(usage, dict) or msg.get("model") == "<synthetic>":
                continue
            key = msg.get("id") or rec.get("requestId") or rec.get("uuid")
            if key not in seen:
                order.append(key)
            seen[key] = (context_of(usage), int(usage.get("output_tokens") or 0))
    return [seen[k] for k in order]


def read_session(path: str) -> dict | None:
    first_ts = None
    role = None
    awaiting_brief = False
    compactions: list[dict] = []
    cost = None
    model = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if role is None or awaiting_brief or "compact_boundary" in line or '"cost-state"' in line or (model is None and '"model"' in line):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
            else:
                continue
            kind = rec.get("type")
            if first_ts is None and rec.get("timestamp"):
                first_ts = rec["timestamp"]
            if kind == "cost-state":
                cost = rec.get("totalCostUSD", cost)
                continue
            if kind == "system" and rec.get("subtype") == "compact_boundary":
                meta = rec.get("compactMetadata") or {}
                compactions.append({"trigger": meta.get("trigger"), "pre": meta.get("preTokens"), "post": meta.get("postTokens")})
                continue
            if kind == "assistant" and model is None:
                m = (rec.get("message") or {}).get("model")
                if m and m != "<synthetic>":
                    model = m
            if kind != "user":
                continue
            body = text_of((rec.get("message") or {}).get("content"))
            if role is None:
                if rec.get("isMeta") or not body.strip():
                    continue
                if DOORBELL in body:
                    role = "pending"
                    awaiting_brief = True
                elif INLINE_BRIEF in body or WORKER_MARK in body:
                    role = "worker" if WORKER_MARK in body else "secondmate"
                else:
                    return None
            elif awaiting_brief and INLINE_BRIEF in body:
                role = "worker" if WORKER_MARK in body else "secondmate"
                awaiting_brief = False
    if role in (None, "pending"):
        return None
    reqs = request_contexts(path)
    if not reqs:
        return None
    sub_total = 0
    stem = path[:-len(".jsonl")]
    for sub in glob.glob(os.path.join(stem, "subagents", "*.jsonl")):
        sub_total += sum(c for c, _ in request_contexts(sub))
    contexts = [c for c, _ in reqs]
    return {
        "session": os.path.basename(stem),
        "dir": os.path.basename(os.path.dirname(path)),
        "started": first_ts or "",
        "role": role,
        "model": model or "",
        "requests": len(reqs),
        "first_request": contexts[0],
        "peak_request": max(contexts),
        "main_context_total": sum(contexts),
        "output_total": sum(o for _, o in reqs),
        "subagent_context_total": sub_total,
        "session_context_total": sum(contexts) + sub_total,
        "compactions": compactions,
        "cost_usd": cost,
    }


def pct(values: list[int], q: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def k(n: float) -> str:
    return f"{n / 1000:.1f}k"


def main() -> int:
    args = parse_args()
    if not os.path.isdir(args.projects):
        print(f"error: transcript root not found: {args.projects}", file=sys.stderr)
        return 1
    since_epoch = None
    for name in ("since", "until"):
        value = getattr(args, name)
        if value is None:
            continue
        try:
            epoch = calendar.timegm(time.strptime(value, "%Y-%m-%d"))
        except ValueError:
            print(f"error: --{name} must be YYYY-MM-DD: {value}", file=sys.stderr)
            return 2
        if name == "since":
            since_epoch = epoch
    rows = []
    for path in sorted(glob.glob(os.path.join(args.projects, "*", "*.jsonl"))):
        # A transcript last written before --since cannot have started after it.
        if since_epoch is not None and os.path.getmtime(path) < since_epoch:
            continue
        row = read_session(path)
        if row is None:
            continue
        day = row["started"][:10]
        if args.since and day < args.since:
            continue
        if args.until and day > args.until:
            continue
        if args.role != "all" and row["role"] != args.role:
            continue
        rows.append(row)

    if args.json:
        for row in rows:
            print(json.dumps(row, sort_keys=True))
        return 0
    if args.sessions:
        print("started\trole\tmodel\trequests\tfirst\tpeak\tmean_request\tsession_total\tcompactions\tcost_usd\tsession")
        for r in sorted(rows, key=lambda r: r["started"]):
            cost = "" if r["cost_usd"] is None else f"{r['cost_usd']:.2f}"
            print("\t".join([r["started"][:16], r["role"], r["model"], str(r["requests"]), k(r["first_request"]), k(r["peak_request"]),
                             k(r["main_context_total"] / r["requests"]), k(r["session_context_total"]), str(len(r["compactions"])), cost,
                             f"{r['dir']}/{r['session']}"]))
        return 0

    print("role\tsessions\trequests\trequest_mean\trequest_p50\trequest_p90\tfirst_mean\tpeak_mean\tsession_mean\tsession_p50\tsession_p90\tcompacted_sessions\tcompactions\tcost_mean_usd")
    for role in sorted({r["role"] for r in rows}):
        group = [r for r in rows if r["role"] == role]
        per_request: list[int] = []
        # Per-request percentiles need every request, so re-read only the
        # selected sessions' main transcripts.
        for r in group:
            per_request.extend(c for c, _ in request_contexts(os.path.join(args.projects, r["dir"], r["session"] + ".jsonl")))
        totals = [r["session_context_total"] for r in group]
        costs = [r["cost_usd"] for r in group if r["cost_usd"] is not None]
        print("\t".join([
            role, str(len(group)), str(len(per_request)),
            k(statistics.fmean(per_request)), k(pct(per_request, 0.5)), k(pct(per_request, 0.9)),
            k(statistics.fmean(r["first_request"] for r in group)), k(statistics.fmean(r["peak_request"] for r in group)),
            k(statistics.fmean(totals)), k(pct(totals, 0.5)), k(pct(totals, 0.9)),
            str(sum(1 for r in group if r["compactions"])), str(sum(len(r["compactions"]) for r in group)),
            f"{statistics.fmean(costs):.2f}" if costs else "",
        ]))
    if not rows:
        print("no Firstmate-launched Claude sessions matched", file=sys.stderr)
    return 0


sys.exit(main())
PY
