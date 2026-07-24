#!/usr/bin/env python3
"""Async auditor — the "watch closely" layer.

The deterministic policy guard makes the decisions; this reviews what actually
happened. Reads audit-log.jsonl, runs a cheap deterministic anomaly scan (the
allow-by-default residual risk: a command that reads a real secret AND makes a
network call, off-sandbox reaches, etc.), and posts a Slack digest: counts,
every DENY/ASK, and any flagged commands. Not in the decision path — pure
oversight, so it never blocks or slows an agent.

Usage:
  audit-digest.py [--since ISO8601] [--label "vaultwarden test"] [--reset]
The orchestrator calls this at run boundaries; --reset truncates the log after.
"""
import os
import sys
import json
import re
import subprocess

HOOKDIR = os.path.dirname(os.path.abspath(__file__))
AUDIT = os.path.join(HOOKDIR, "audit-log.jsonl")

# Deterministic anomaly heuristics over an ALLOW'd command — the residual risks
# of allow-by-default worth a human glance even though nothing was blocked.
SECRETISH = re.compile(r"(reveal|id_rsa|\.pem|PRIVATE KEY|password|secret|token|credential)", re.I)
NETWORK = re.compile(r"\b(curl|wget|nc|scp|ssh|rsync)\b")
EXTERNAL = re.compile(r"https?://(?!(localhost|127\.0\.0\.1|[^\s/]*\.cpln\.(local|app)|api\.cpln\.io))", re.I)


def flags(subj):
    out = []
    if SECRETISH.search(subj) and NETWORK.search(subj) and EXTERNAL.search(subj):
        out.append("secret-ish token + network call to an external host")
    return out


def main():
    args = sys.argv[1:]
    since = None
    label = ""
    reset = "--reset" in args
    if "--since" in args:
        since = args[args.index("--since") + 1]
    if "--label" in args:
        label = args[args.index("--label") + 1]
    try:
        lines = open(AUDIT).read().splitlines()
    except Exception:
        lines = []
    rows = []
    for ln in lines:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if since and d.get("ts", "") < since:
            continue
        rows.append(d)
    allow = [r for r in rows if r["decision"] == "allow"]
    ask = [r for r in rows if r["decision"] == "ask"]
    deny = [r for r in rows if r["decision"] == "deny"]
    flagged = [(r, flags(r["subject"])) for r in allow]
    flagged = [(r, f) for r, f in flagged if f]

    L = f" — {label}" if label else ""
    text = [f":mag: [templates] audit digest{L}: {len(rows)} commands "
            f"({len(allow)} allow / {len(ask)} ask / {len(deny)} deny)"]
    for r in ask:
        text.append(f"  :raised_hand: ASK — {r['reason']}: `{r['subject'][:90]}`")
    for r in deny:
        text.append(f"  :no_entry: DENY — {r['reason']}: `{r['subject'][:90]}`")
    if flagged:
        text.append("  :warning: flagged (allowed but worth a look):")
        for r, f in flagged[:10]:
            text.append(f"    • {', '.join(f)}: `{r['subject'][:90]}`")
    if not ask and not deny and not flagged:
        text.append("  :white_check_mark: nothing needed you; no anomalies flagged.")
    msg = "\n".join(text)

    url = os.environ.get("SLACK_WEBHOOK_URL")
    if url:
        subprocess.run(["curl", "-s", "-m", "10", "-X", "POST", "-H", "Content-type: application/json",
                        "--data", json.dumps({"text": msg}), url],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(msg)

    if reset:
        try:
            open(AUDIT, "w").close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
