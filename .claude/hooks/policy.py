#!/usr/bin/env python3
"""Deterministic permission policy for the template pipeline.

Model (maintainer-designed 2026-07-24): ALLOW by default. The agents have
proven ~95% aligned; the job of this layer is not to prove every command safe
(an infinite space) but to catch the small, knowable set of catastrophic or
org-touching actions. Three tiers, all deterministic — NO LLM in the decision
path, so behavior is predictable:

  DENY  — irreversible / beyond-sandbox; never legitimate for template testing.
  ASK   — org-infrastructure changes; may occasionally be needed, so pause and
          request the maintainer rather than block. Never auto-accepted.
  ALLOW — everything else (test-GVC ops, reads, workload/template work, clients
          against test endpoints, repo/scratchpad/docs writes, git/gh on
          branches, dev installs, HTTPS fetches, internal HTTP).

`decide(payload) -> (decision, reason)` where decision in allow|ask|deny.
"""
import re

SANCTIONED_GVCS = ("test-gvc", "test-gvc-2", "test-gvc-3")
TEST_PREFIXES = ("test-", "trial-", "dev-", "foo-", "bar-")
SAFE_ROOTS = (
    "/Users/jacobcox/code/control-plane/",
    "/private/tmp/claude-501/",
    "/tmp/",
    "/Users/jacobcox/.claude/projects/-Users-jacobcox-code-control-plane-templates/",
)
# Internal / mesh hosts that legitimately speak plain HTTP (the attested mesh,
# loopback, internal DNS, the platform API). External HTTP is denied.
INTERNAL_HTTP_OK = re.compile(
    r"(localhost|127\.0\.0\.1|\[::1\]|(^|[./@])10\.\d+\.\d+\.\d+|\.cpln\.local|api\.cpln\.io|\.svc(\.|:|/|$))",
    re.I,
)

# ── DENY: catastrophic / beyond-sandbox (hard-block + ping) ──────────────────
DENY = [
    (re.compile(r"\bgit\s+push\b[^|;&]*\borigin\s+main\b"), "push to main bypasses PR review"),
    (re.compile(r"\bgit\s+push\b[^|;&]*(\s-f\b|--force)"), "force-push is irreversible history rewrite"),
    (re.compile(r"\bgh\s+pr\s+merge\b"), "PR merges are the maintainer's gate"),
    (re.compile(r"\bcpln\s+(org|gvc)\s+delete\b"), "org/GVC deletion is catastrophic"),
    (re.compile(r"\bsudo\b"), "sudo/root change — routed to maintainer unless repo-scoped (see refine)"),
    # billable cloud provisioning outside the test setup
    (re.compile(r"\baws\s+ec2\s+run-instances\b|\bgcloud\s+compute\s+instances\s+create\b|\baz\s+vm\s+create\b"),
     "provisioning billable cloud compute"),
]

# ── ASK: org-infrastructure changes (ping + wait for approval) ───────────────
ASK = [
    (re.compile(r"\bcpln\s+serviceaccount\s+(create|delete|update|add|remove)\b"), "org service-account change"),
    (re.compile(r"\bcpln\s+group\s+(create|delete|update)\b"), "org group change"),
    (re.compile(r"\bcpln\s+org\s+update\b"), "org settings change"),
    (re.compile(r"\bcpln\s+cloudaccount\s+delete\b"), "deleting a shared cloud account"),
    # recursive object-store delete at bucket root or a foreign prefix
    (re.compile(r"\b(aws\s+s3\s+rm|mc\s+rm|gsutil\s+-m?\s*rm|gcloud\s+storage\s+rm)\b[^|;&]*(--recursive|-r\b|\*)"),
     "recursive object-store delete"),
]

READONLY_CPLN_VERBS = {"get", "list", "logs", "query", "get-deployments", "eventlog",
                       "access-report", "whoami", "version", "profile", "help"}
CPLN_MUTATING = re.compile(r"\bcpln\b")

# A network CLIENT actually makes a request; other programs that merely carry an
# http:// string (helm --set endpoint=..., cpln, echo) do not. Only flag
# external plain-HTTP when a client is present (fixes the helm-render false deny).
# Note: no bare "http" here — it would match the "http" inside an http:// URL
# and defeat the check. httpie's real command names are covered.
NET_CLIENTS = re.compile(r"\b(curl|wget|ncat|httpie|nc)\b")

# Raw cloud CLIs reach real cloud accounts — scope their MUTATIONS like cpln.
CLOUD_CLIS = ("aws", "gcloud", "gsutil", "az")
TEST_BUCKETS = ("cpln-test-bucket",)
_CLOUD_MUT = re.compile(
    r"\b(rm|mv|cp|sync|mirror|put|mb|rb|delete|create|remove|run-instances|"
    r"terminate|modify|reboot|stop|start|update|set-[a-z-]+|attach|detach|"
    r"put-[a-z-]+|delete-[a-z-]+|create-[a-z-]+)\b")

# Credential / key material that template testing never needs to read. Matched
# only OUTSIDE the sandbox — a test's own generated key in scratchpad is fine.
SENSITIVE = re.compile(
    r"(/\.ssh/|\bid_rsa\b|\bid_ed25519\b|\bid_dsa\b|/\.aws/credentials|/\.aws/config|"
    r"/\.config/gcloud/|/\.azure/|\.keychain\b|/\.netrc\b|/\.docker/config\.json|"
    r"/\.kube/config)", re.I)


def _cloud_concern(seg):
    """Cloud-CLI mutation not scoped to the sanctioned test bucket -> ask.
    Reads are harmless anywhere; test-bucket object ops are allowed."""
    words = seg.split()
    if not any(w.split("/")[-1] in CLOUD_CLIS for w in words):
        return None
    if not _CLOUD_MUT.search(seg.lower()):
        return None  # read-only cloud call (ls/list/describe/get...) -> allow
    buckets = re.findall(r"(?:s3|gs)://([^/\s\"']+)", seg)
    if buckets and all(b in TEST_BUCKETS for b in buckets):
        return None  # object op entirely within the test bucket -> allow
    return "cloud-CLI mutation outside the sanctioned test bucket"


def _sensitive_read(cmd):
    """Reading credential/key material outside the sandbox -> ask."""
    for m in re.finditer(r"((?:/|~/|\$HOME/)[^\s\"';|&]+)", cmd):
        p = m.group(1).replace("~/", "/Users/jacobcox/").replace("$HOME/", "/Users/jacobcox/")
        if SENSITIVE.search(p) and not p.startswith(SAFE_ROOTS):
            return True
    return False


def _split_top(cmd):
    """Quote-aware split into top-level segments on ; && | and newlines."""
    segs, cur, quote, i, n = [], [], None, 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c; cur.append(c)
        elif c in ";|\n":
            segs.append("".join(cur)); cur = []
        elif c == "&" and cmd[i:i + 2] == "&&":
            segs.append("".join(cur)); cur = []; i += 1
        else:
            cur.append(c)
        i += 1
    segs.append("".join(cur))
    return segs


def _cpln_non_test_gvc_mutation(seg):
    """A cpln command that mutates a GVC other than the sanctioned test ones."""
    if "cpln" not in seg:
        return False
    words = seg.split()
    idx = next((i for i, w in enumerate(words) if w.split("/")[-1] == "cpln"), -1)
    if idx < 0:
        return False
    rest = words[idx + 1:]
    nonflag = [w for w in rest if not w.startswith("-")]
    if any(v in READONLY_CPLN_VERBS for v in nonflag[:2]):
        return False  # reads are always fine
    m = re.search(r"--gvc[= ]+(\S+)", seg)
    if m:
        return m.group(1).strip("\"'") not in SANCTIONED_GVCS
    return False


def _external_http(cmd):
    """A network CLIENT hitting a plain-HTTP EXTERNAL host. An http:// string in
    a non-client command (helm --set, cpln, echo) is a config value, not a
    request, so it does not count."""
    if not NET_CLIENTS.search(cmd):
        return False
    for m in re.finditer(r"http://([^\s\"'/]+)", cmd):
        host = m.group(0)
        if not INTERNAL_HTTP_OK.search(host):
            return True
    return False


def _sudo_repo_scoped(cmd):
    """sudo is allowed only when it operates strictly inside the sandbox."""
    # crude but safe: every path-looking token after sudo must be under SAFE_ROOTS
    after = cmd.split("sudo", 1)[1]
    paths = re.findall(r"(/[^\s\"';|&]+)", after)
    return bool(paths) and all(p.startswith(SAFE_ROOTS) for p in paths)


def decide_bash(cmd):
    # DENY checks (whole-command, catch wherever they appear)
    for pat, why in DENY:
        if pat.search(cmd):
            if why.startswith("sudo") and _sudo_repo_scoped(cmd):
                continue  # repo-scoped sudo is contained -> allowed
            return "deny", why
    if _external_http(cmd):
        return "deny", "plain-HTTP request to an external host (traffic must be HTTPS)"
    for seg in _split_top(cmd):
        if _cpln_non_test_gvc_mutation(seg):
            return "deny", "cpln mutation targets a non-test GVC"
    # ASK checks (org infrastructure)
    for pat, why in ASK:
        if pat.search(cmd):
            return "ask", why
    # direct org-scoped policy mutation with a non-test-prefixed name
    m = re.search(r"\bcpln\s+policy\s+(create|delete|update)\s+(\S+)", cmd)
    if m and not m.group(2).strip("\"'").startswith(TEST_PREFIXES):
        return "ask", "org policy change (non-test-scoped)"
    # raw cloud-CLI mutation reaching beyond the sanctioned test bucket
    for seg in _split_top(cmd):
        c = _cloud_concern(seg)
        if c:
            return "ask", c
    # reading credential/key material outside the sandbox
    if _sensitive_read(cmd):
        return "ask", "reading credential/key material outside the sandbox"
    return "allow", "default-allow (no deny/ask pattern matched)"


def decide(payload):
    tn = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    # reads are allowed — except credential/key material outside the sandbox
    if tn in ("Read", "Glob", "Grep", "LS", "WebSearch"):
        p = str(ti.get("file_path") or ti.get("path") or "")
        if p and SENSITIVE.search(p) and not p.startswith(SAFE_ROOTS):
            return "ask", "reading credential/key material outside the sandbox"
        return "allow", "read-only tool"
    if tn in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        p = str(ti.get("file_path") or ti.get("notebook_path") or "")
        if p.startswith(SAFE_ROOTS):
            return "allow", "write inside the sandbox"
        return "deny", "write outside the repo/scratchpad/docs/memory sandbox"
    if tn == "WebFetch":
        u = str(ti.get("url") or "")
        if u.startswith("http://") and not INTERNAL_HTTP_OK.search(u):
            return "deny", "plain-HTTP fetch of an external host (must be HTTPS)"
        return "allow", "web fetch"
    if tn in ("", "Bash") and ti.get("command"):
        return decide_bash(str(ti.get("command")))
    # MCP cpln tools and anything else: conservative default for mutations
    name = tn.lower()
    if name.startswith("mcp__") and any(k in name for k in ("delete", "update", "create")):
        if any(k in name for k in ("serviceaccount", "policy", "group", "cloudaccount", "org")):
            return "ask", "org-infrastructure change via MCP tool"
        return "allow", "cpln MCP resource op (test-scoped by workflow)"
    return "allow", "no policy match -> default allow"


if __name__ == "__main__":
    import sys, json
    try:
        d = json.load(sys.stdin)
    except Exception:
        print("allow\tunparseable payload -> allow"); raise SystemExit(0)
    decision, reason = decide(d)
    print(decision + "\t" + reason)
