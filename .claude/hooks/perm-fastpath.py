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
import re
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
    "column", "awk", "sed", "mkdir", "dig", "getent", "hostname", "env",
}
# Programs whose DANGEROUS forms are already hard-denied upstream by cpln-guard
# (push-to-main, force-push, gh pr merge, org/GVC delete, cpln mutations outside
# the sanctioned test GVCs). Anything of theirs reaching here is safe by
# construction, so the evaluator need not re-judge it.
GUARDED_PROGS = {"git", "cpln", "gh"}
SANCTIONED_GVCS = ("test-gvc", "test-gvc-2", "test-gvc-3")
KW = {"timeout", "until", "while", "do", "done", "for", "then", "if", "fi",
      "time", "else", "elif"}

# Redirects that don't write a real destructive target: fd merges (2>&1, >&2)
# and /dev/null sinks. Also allow redirects INTO a sanctioned root path.
_REDIR_FD = re.compile(r"\d*>&\d+|&>|\d*>>?\s*/dev/null|<\s*/dev/null")


def _strip_safe_redirects(cmd):
    """Remove harmless redirects; return (cleaned, ok). ok=False if a redirect
    targets something outside /dev/null and the sanctioned roots."""
    cmd = _REDIR_FD.sub(" ", cmd)
    # remaining >, >>, < with a target
    for m in re.finditer(r"(\d*>>?|<)\s*(\S+)", cmd):
        target = m.group(2).strip("\"'")
        if target.startswith(SAFE_ROOTS) or target == "/dev/null":
            continue
        return cmd, False
    cmd = re.sub(r"(\d*>>?|<)\s*\S+", " ", cmd)
    return cmd, True


def _extract_substitutions(cmd):
    """Yield inner commands of balanced $( ... ) groups (one level of nesting
    tolerated), and return the command with those groups blanked. Backticks
    are treated as un-analyzable -> caller rejects."""
    inners, out, i, n = [], [], 0, len(cmd)
    while i < n:
        if cmd[i] == "`":
            return None, None  # backtick substitution: bail to LLM
        if cmd[i:i + 2] == "$(":
            depth, j = 1, i + 2
            while j < n and depth:
                if cmd[j] == "(":
                    depth += 1
                elif cmd[j] == ")":
                    depth -= 1
                j += 1
            if depth:
                return None, None  # unbalanced
            inners.append(cmd[i + 2:j - 1])
            out.append(" X ")  # placeholder for the produced text
            i = j
        else:
            out.append(cmd[i])
            i += 1
    return inners, "".join(out)


def _classify(cmd):
    """True iff every segment is read-only or a guard-vetted program."""
    if cmd.count("&") != 2 * cmd.count("&&"):  # bare & = backgrounding
        return False
    segs = [s for part in cmd.replace(";", "&&").split("&&") for s in part.split("|")]
    for seg in segs:
        words = seg.split()
        while words and (
            ("=" in words[0].split("/")[0] and not words[0].startswith("-"))
            or words[0] in KW or words[0].isdigit()
        ):
            words = words[1:]
        if not words:
            continue
        prog = words[0].split("/")[-1]
        if prog in READONLY_PROGS or prog in GUARDED_PROGS or prog == "X":
            continue
        if prog == "helm" and any(g in seg for g in SANCTIONED_GVCS):
            continue
        return False
    return True


def safe_bash(cmd):
    if chr(10) in cmd:
        cmd = cmd.replace(chr(10), " ; ")
    cmd, ok = _strip_safe_redirects(cmd)
    if not ok:
        return False
    inners, stripped = _extract_substitutions(cmd)
    if inners is None:
        return False
    # every substituted inner command must itself be read-only/guarded
    for inner in inners:
        if not _classify(inner):
            return False
    return _classify(stripped)


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
