#!/usr/bin/env python3
"""PreToolUse guard — the deterministic permission layer for the pipeline.

Replaces the old cpln-guard + LLM-evaluator stack. Uses policy.decide()
(deterministic, allow-by-default; see policy.py) to emit a PreToolUse
permissionDecision. Logs EVERY decision to audit-log.jsonl for the async
auditor / Slack digest, and pings the maintainer (desktop + Slack) on any
deny or ask so nothing blocks silently. No LLM in the decision path.
"""
import os
import sys
import json
import datetime
import subprocess

HOOKDIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOKDIR)
from policy import decide  # noqa: E402

AUDIT = os.path.join(HOOKDIR, "audit-log.jsonl")


def subject(payload):
    ti = payload.get("tool_input") or {}
    if payload.get("tool_name") in (None, "", "Bash") and ti.get("command"):
        return str(ti["command"])
    return (payload.get("tool_name") or "tool") + ": " + json.dumps(ti)[:400]


def now():
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(decision, reason, subj):
    try:
        with open(AUDIT, "a") as f:
            f.write(json.dumps({"ts": now(), "decision": decision,
                                "reason": reason, "subject": subj[:4000]}) + "\n")
    except Exception:
        pass


def ping(decision, reason, subj):
    snip = " ".join(subj.split())[:120]
    icon = ":no_entry:" if decision == "deny" else ":raised_hand:"
    verb = "DENIED" if decision == "deny" else "approval needed"
    try:
        subprocess.Popen([os.path.join(HOOKDIR, "desktop-notify.sh")],
                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL).stdin.write(
            json.dumps({"message": f"{verb}: {reason} — {snip}"}).encode())
    except Exception:
        pass
    url = os.environ.get("SLACK_WEBHOOK_URL")
    if url:
        try:
            subprocess.Popen(
                ["curl", "-s", "-m", "10", "-X", "POST", "-H", "Content-type: application/json",
                 "--data", json.dumps({"text": f"{icon} [templates] {verb} — {reason}\n`{snip}`"}), url],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # unparseable -> no opinion, normal flow
    decision, reason = decide(payload)
    subj = subject(payload)
    log(decision, reason, subj)
    if decision in ("deny", "ask"):
        ping(decision, reason, subj)
    # PreToolUse: "allow" runs with no prompt, "deny" blocks, "ask" -> prompt.
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": f"policy ({decision}): {reason}",
    }}))
    sys.exit(0)


if __name__ == "__main__":
    main()
