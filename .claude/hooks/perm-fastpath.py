#!/usr/bin/env python3
"""Deterministic fast-path for the permission evaluator.

Reads the PermissionRequest payload as JSON on stdin; prints a one-line
`ALLOW: <reason> (fast-path)` verdict for objectively-safe requests, or
nothing (so perm-eval.sh falls through to the LLM). Split into its own file
because macOS bash 3.2 mishandles a heredoc inside $() — inlining this in the
hook broke the whole evaluator. Conservative by construction: any construct
that could write or execute arbitrary code, or reach a non-sanctioned target,
prints nothing and gets full LLM judgment.
"""
import sys
import json
from urllib.parse import urlparse

SAFE_ROOTS = (
    "/Users/jacobcox/code/control-plane/",
    "/private/tmp/claude-501/",
    "/tmp/",
    "/Users/jacobcox/.claude/projects/-Users-jacobcox-code-control-plane-templates/memory/",
)
READONLY_PROGS = {
    "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "sort", "uniq",
    "cut", "tr", "echo", "printf", "date", "pwd", "stat", "file", "basename",
    "dirname", "diff", "which", "true", "cd", "sleep", "test", "seq", "jq", "yq",
    "column", "awk", "sed", "mkdir", "dig", "getent",
}
# Programs whose DANGEROUS forms are already hard-denied upstream by cpln-guard
# (push-to-main, force-push, gh pr merge, org/GVC delete, cpln mutations outside
# the sanctioned test GVCs). Anything of theirs reaching here is safe by
# construction, so the evaluator need not re-judge it.
GUARDED_PROGS = {"git", "cpln", "gh"}
SANCTIONED_GVCS = ("test-gvc", "test-gvc-2", "test-gvc-3")
KW = {"timeout", "until", "while", "do", "done", "for", "then", "if", "fi", "time"}


def safe_bash(cmd):
    # Reject constructs that could smuggle a side effect past per-segment
    # classification: substitution, redirects, backgrounding. Separators
    # (; && |) are fine since every resulting segment is checked.
    if any(tok in cmd for tok in ("$(", chr(96), ">", "<", chr(10))):
        return False
    if cmd.count("&") != 2 * cmd.count("&&"):
        return False
    segs = [s for part in cmd.replace(";", "&&").split("&&") for s in part.split("|")]
    for seg in segs:
        words = seg.split()
        while words and (
            ("=" in words[0].split("/")[0] and not words[0].startswith("-"))
            or words[0] in KW
            or words[0].isdigit()
        ):
            words = words[1:]
        if not words:
            continue
        prog = words[0].split("/")[-1]
        if prog in READONLY_PROGS or prog in GUARDED_PROGS:
            continue
        if prog == "helm" and any(g in seg for g in SANCTIONED_GVCS):
            continue
        return False  # unknown program (python/node/curl/psql/rm/...) -> LLM
    return True


def verdict(d):
    tn = d.get("tool_name") or ""
    ti = d.get("tool_input") or {}
    if tn in ("Read", "Glob", "Grep", "WebSearch"):
        return "ALLOW: read-only tool (fast-path)"
    if tn in ("", "Bash") and ti.get("command") and safe_bash(str(ti.get("command"))):
        return "ALLOW: read-only or guard-vetted shell (fast-path)"
    if tn in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        p = str(ti.get("file_path") or ti.get("notebook_path") or "")
        if p.startswith(SAFE_ROOTS):
            return "ALLOW: file write inside sanctioned surfaces (fast-path)"
    if tn == "WebFetch":
        u = str(ti.get("url") or "")
        try:
            parsed = urlparse(u)
            if (parsed.scheme in ("http", "https") and "@" not in (parsed.netloc or "")
                    and not any(k in u.lower() for k in ("token=", "key=", "password=", "secret="))):
                return "ALLOW: public web fetch, no embedded credentials (fast-path)"
        except Exception:
            pass
    return ""


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    print(verdict(d))


if __name__ == "__main__":
    main()
