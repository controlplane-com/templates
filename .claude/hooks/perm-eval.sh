#!/bin/bash
# ENFORCING permission evaluator (flipped from shadow 2026-07-23 after the
# maintainer-delegated 55-decision review: zero wrong-side ALLOWs; rubric
# rewritten containment-first + model upgraded to sonnet the same day).
# Evaluates EVERY permission request — shell commands AND other tool calls
# (Write/Edit/WebFetch/...). Emits permissionDecision "allow" ONLY on a
# confident ALLOW verdict; on ASK, eval error, or timeout it emits NOTHING and
# the normal human prompt appears — preceded by a desktop banner + Slack ping,
# because the VS Code extension emits no Notification event for permission
# prompts (verified live 2026-07-23) and background-agent prompts are otherwise
# silent. Human approvals after an ASK are captured by perm-learn.sh
# (PostToolUse) into perm-overrides.log and folded into the rubric at each
# template ship-close — the learning loop.
# Hard-denies (cpln-guard) run upstream and outrank this entirely.
LOG="$(dirname "$0")/perm-decisions.log"
payload=$(cat)

# ── Deterministic fast-path (added 2026-07-24) ──────────────────────────────
# Under parallel-agent load, LLM evaluation (5–15s each) makes permission
# cards visibly queue and occasionally EVAL-ERROR. The objectively-safe bulk
# never needs judgment: decide it in <100ms. Anything not matched falls
# through to the LLM exactly as before. Conservative by design.
fast=$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); tn = d.get("tool_name") or ""; ti = d.get("tool_input") or {}
except Exception:
    sys.exit(0)
SAFE_ROOTS = ("/Users/jacobcox/code/control-plane/", "/private/tmp/claude-501/", "/tmp/",
              "/Users/jacobcox/.claude/projects/-Users-jacobcox-code-control-plane-templates/memory/")
if tn in ("Read", "Glob", "Grep", "WebSearch"):
    print("ALLOW: read-only tool (fast-path)")
elif tn in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
    p = str(ti.get("file_path") or ti.get("notebook_path") or "")
    if p.startswith(SAFE_ROOTS):
        print("ALLOW: file write inside sanctioned surfaces (fast-path)")
elif tn == "WebFetch":
    u = str(ti.get("url") or "")
    try:
        from urllib.parse import urlparse
        parsed = urlparse(u)
        clean = (parsed.scheme in ("http", "https")
                 and "@" not in (parsed.netloc or "")
                 and not any(k in u.lower() for k in ("token=", "key=", "password=", "secret=")))
    except Exception:
        clean = False
    if clean:
        print("ALLOW: public web fetch, no embedded credentials (fast-path)")
' 2>>"$LOG")
if [ -n "$fast" ]; then
  python3 - "$payload" "$fast" >>"$LOG" 2>&1 <<'PYEOF'
import sys, json, datetime
try:
    d = json.loads(sys.argv[1]); ti = d.get("tool_input") or {}
    subj = "TOOL: " + str(d.get("tool_name")) + " " + json.dumps(ti)[:500]
except Exception:
    subj = "unparseable"
print(json.dumps({"ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "mode": "enforce", "command": subj, "decision": sys.argv[2]}))
PYEOF
  reason=$(printf '%s' "${fast#ALLOW: }" | head -c 200)
  python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','permissionDecision':'allow','permissionDecisionReason':'auto-approved (fast-path): '+sys.argv[1]}}))" "$reason"
  exit 0
fi
# ────────────────────────────────────────────────────────────────────────────

# Build the evaluation subject: shell command text, or TOOL: name + JSON input.
subject=$(printf '%s' "$payload" | python3 -c 'import sys,json
try:
  d = json.load(sys.stdin); ti = d.get("tool_input") or {}
  cmd = ti.get("command")
  if d.get("tool_name") in (None, "Bash") and cmd:
    print(cmd)
  else:
    print("TOOL: " + str(d.get("tool_name") or "unknown") + " " + json.dumps(ti)[:2000])
except Exception:
  print("")' 2>>"$LOG")
[ -z "$subject" ] && exit 0

# Internal timeout MUST stay under the hook's 90s registration timeout: if the
# CLI hangs, we still return a decision (empty verdict → deny + ping) instead
# of the harness killing the hook and silently falling through to a waiting
# human prompt — the one hole zero-prompt mode cannot tolerate.
# NOTE: macOS ships no `timeout` binary (a bare `timeout 70 claude ...` broke
# every evaluation into deny on 2026-07-24) — python subprocess owns the clock.
verdict=$(PERM_SUBJECT="$subject" python3 - "$(dirname "$0")/permission-rubric.md" <<'PY' 2>>"$LOG"
import os, subprocess, sys
prompt = open(sys.argv[1]).read() + "\n\nREQUEST TO EVALUATE:\n" + os.environ["PERM_SUBJECT"]
try:
    r = subprocess.run(["claude", "--model", "claude-sonnet-5", "-p", prompt],
                       capture_output=True, text=True, timeout=70)
    lines = (r.stdout or "").strip().splitlines()
    print(lines[0] if lines else "")
except Exception:
    print("")
PY
)

python3 - "$subject" "$verdict" >>"$LOG" 2>&1 <<'PYEOF'
import sys, json, datetime
print(json.dumps({"ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "mode": "enforce", "command": sys.argv[1][:4000], "decision": sys.argv[2] or "EVAL-ERROR"}))
PYEOF

case "$verdict" in
  ALLOW:*)
    reason=$(printf '%s' "${verdict#ALLOW: }" | head -c 200)
    python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','permissionDecision':'allow','permissionDecisionReason':'auto-approved (pipeline evaluator): '+sys.argv[1]}}))" "$reason"
    ;;
  *)
    # ZERO-PROMPT MODE (maintainer directive 2026-07-24): ASK / eval-error →
    # AUTO-DENY with a mandatory maintainer ping (banner + Slack). No human
    # prompt ever appears; the agent adapts within sanctioned surfaces or
    # reports blocked. Wrong denies are visible to the maintainer and get
    # folded into the rubric like overrides did.
    reason=$(printf '%s' "${verdict#ASK: }" | head -c 160)
    snip=$(printf '%s' "$subject" | tr '\n' ' ' | head -c 120)
    {
      python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' \
        "Auto-DENIED: ${reason:-evaluation error} — ${snip}" \
        | "$(dirname "$0")/desktop-notify.sh"
      if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' \
          ":no_entry: [templates] auto-DENIED — ${reason:-evaluation error}
\`${snip}\`
_(evaluator deny; if this looks wrong, tell the orchestrator and it gets folded into the rubric)_" \
          | curl -s -m 10 -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK_URL"
      fi
    } >/dev/null 2>&1 &
    python3 -c "import json,sys; print(json.dumps({'hookSpecificOutput':{'hookEventName':'PermissionRequest','permissionDecision':'deny','permissionDecisionReason':'auto-denied (pipeline evaluator): '+sys.argv[1]+' — the maintainer has been pinged; rephrase the action to stay within sanctioned surfaces (repo/scratchpad/test-GVC/docs) or report yourself blocked. Do not retry the identical request.'}}))" "${reason:-evaluation error}"
    ;;
esac
exit 0
