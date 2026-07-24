#!/usr/bin/env python3
"""PreToolUse guard for cpln commands — the pipeline's deterministic blast-radius rail.

Decision semantics (Claude Code PreToolUse):
  - permissionDecision "allow": command runs with NO permission prompt
  - permissionDecision "deny":  command is blocked; reason is shown to the model
  - no output / exit 0:         no opinion -> normal permission flow (prompt/allowlist)

Policy:
  - Read-only cpln commands: always allowed (logs, get, list, whoami, ...).
  - Mutating cpln commands WITH --gvc: allowed iff the gvc is $CPLN_TEST_GVC; any
    other gvc is DENIED outright.
  - Org-scoped mutations (no --gvc, e.g. secret delete): allowed only when every
    positional resource name carries a test prefix (test-|trial-|dev-|foo-|bar-).
  - Pipelines are allowed when every segment is a permitted cpln command or a safe
    read-only filter (grep/awk/python3/...). Anything the parser is not sure about
    falls through to the normal permission prompt — never to allow.
"""
import json
import os
import re
import sys

TEST_PREFIXES = ("test-", "trial-", "dev-", "foo-", "bar-")

CONTROL_WORDS = {"until", "while", "do", "done", "then", "fi", "if", "for", "time", "!"}

SAFE_UTILS = {
    "grep", "egrep", "fgrep", "awk", "sed", "head", "tail", "sort", "uniq", "wc",
    "tr", "cut", "cat", "echo", "printf", "python3", "jq", "yq", "sleep", "true",
    "date", "paste", "column", "file", "ls", "basename",
}

READONLY_CPLN = (
    "logs",
    "workload get",          # covers get and get-deployments
    "workload list",
    "workload eventlog",
    "workload access-report",
    "volumeset get",
    "secret get",
    "helm list",
    "gvc get",
    "image get",
    "policy get",
    "identity get",
    "org get",
    "profile",
    "whoami",
    "version",
    "query",
)


def notify_deny(reason: str, cmd: str) -> None:
    """Best-effort maintainer ping on every guard deny (banner + Slack).
    Zero-prompt mode means denies must never be silent. Never blocks/raises."""
    import subprocess
    hookdir = os.path.dirname(os.path.abspath(__file__))
    snip = " ".join(cmd.split())[:120]
    try:
        subprocess.Popen(
            [os.path.join(hookdir, "desktop-notify.sh")],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).stdin.write(json.dumps({"message": f"GUARD hard-deny: {reason} — {snip}"}).encode())
    except Exception:
        pass
    url = os.environ.get("SLACK_WEBHOOK_URL")
    if url:
        try:
            subprocess.Popen(
                ["curl", "-s", "-m", "10", "-X", "POST", "-H", "Content-type: application/json",
                 "--data", json.dumps({"text": f":rotating_light: [templates] GUARD hard-deny — {reason}\n`{snip}`"}),
                 url],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass


def out(decision: str, reason: str, cmd: str = "") -> None:
    if decision == "deny":
        notify_deny(reason, cmd)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def split_segments(cmd: str):
    """Quote-aware split on | ; & and newlines. Returns None if parsing is unsafe."""
    segs, cur, quote = [], "", None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            cur += c
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            cur += c
        elif c == "\\" and i + 1 < len(cmd):
            cur += cmd[i:i + 2]
            i += 1
        elif c in "|;&\n":
            if cur.strip():
                segs.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if quote is not None:
        return None  # unbalanced quotes -> not confident
    if cur.strip():
        segs.append(cur.strip())
    return segs


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (data.get("tool_input") or {}).get("command", "") or ""
    # ── Deterministic hard-denies (maintainer gates + irreversibles) ──
    # These outrank any LLM permission evaluator by design: the evaluator only
    # ever adjudicates commands that survive this layer.
    import re as _re
    HARD_DENY = [
        (r"\bgh\s+pr\s+merge\b", "PR merges are the maintainer's gate — never automated"),
        (r"\bgit\s+push\b[^|;&]*(\s-f\b|--force)", "force-push is irreversible history rewrite"),
        (r"\bgit\s+push\b[^|;&]*\borigin\s+main\b", "direct pushes to main bypass PR review"),
        (r"\bcpln\s+(org|gvc)\s+delete\b", "org/GVC deletion is never pipeline work"),
    ]
    for pat, why in HARD_DENY:
        if _re.search(pat, cmd):
            out("deny", f"cpln guard hard-deny: {why}", cmd)

    if "cpln" not in cmd:
        sys.exit(0)  # not ours; normal flow

    test_gvc = os.environ.get("CPLN_TEST_GVC", "test-gvc")
    # test-gvc-2 (2026-07-20) and test-gvc-3 (2026-07-24) are the maintainer-
    # sanctioned parallel test slots. The env var loads at session start,
    # so a set is safer than swapping the var mid-session.
    allowed_gvcs = {test_gvc, "test-gvc", "test-gvc-2", "test-gvc-3"}

    segs = split_segments(cmd)
    if segs is None:
        sys.exit(0)

    verdicts = []
    for seg in segs:
        words = seg.split()
        # strip loop/conditional keywords and `timeout N`
        while words and (words[0] in CONTROL_WORDS or words[0] == "timeout" or words[0].isdigit()):
            words = words[1:]
        if not words:
            continue
        prog = words[0]
        if prog != "cpln":
            if prog in SAFE_UTILS:
                continue
            sys.exit(0)  # unknown segment (bash -c, curl, ...): normal prompt

        rest = " ".join(words[1:])
        if any(rest == p or rest.startswith(p + " ") or rest.startswith(p + "-") or rest.startswith(p)
               for p in READONLY_CPLN):
            verdicts.append("read-only")
            continue

        # mutating cpln command
        m = re.search(r"--gvc[= ]+(\S+)", seg)
        if m:
            raw = m.group(1)
            gv = raw.strip("'\"")
            if gv in allowed_gvcs or gv in ("$CPLN_TEST_GVC", "${CPLN_TEST_GVC}"):
                verdicts.append("mutation-in-test-gvc")
                continue
            out("deny",
                f"cpln guard: mutation targets gvc '{gv}' — automated runs may only mutate "
                f"the sanctioned test GVCs. Blocked deterministically.", cmd)

        # org-scoped mutation: every positional name must be test-prefixed
        positionals = [w.strip("'\"") for w in words[1:] if not w.startswith("-")]
        names = positionals[2:] if len(positionals) > 2 else []
        if names and all(n.startswith(TEST_PREFIXES) for n in names):
            verdicts.append("org-scoped-test-resource")
            continue

        sys.exit(0)  # ambiguous mutation: let the human decide via normal prompt

    if verdicts:
        out("allow", "cpln guard: " + ", ".join(sorted(set(verdicts))))
    sys.exit(0)


if __name__ == "__main__":
    main()
