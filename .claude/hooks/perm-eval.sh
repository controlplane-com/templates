#!/bin/bash
# ENFORCING permission evaluator (flipped from shadow 2026-07-23 after the
# maintainer-delegated 55-decision review: zero wrong-side ALLOWs).
# Emits permissionDecision "allow" ONLY on a confident ALLOW verdict; on ASK,
# eval error, or timeout it emits NOTHING and the normal human prompt appears.
# Hard-denies (cpln-guard) run upstream and outrank this entirely.
# Revert: swap settings.local.json PermissionRequest hook back to perm-eval-shadow.sh.
LOG="$(dirname "$0")/perm-decisions.log"
payload=$(cat)
cmd=$(printf '%s' "$payload" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("tool_input") or {}).get("command",""))
except Exception: print("")' 2>>"$LOG")

# Non-Bash tool prompt (Edit/Write/WebFetch/MCP/...): no LLM evaluation, but a
# human prompt IS about to appear and the VS Code extension emits no Notification
# event for it (verified 2026-07-23) — so ping the maintainer from here.
if [ -z "$cmd" ]; then
  summary=$(printf '%s' "$payload" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); ti=d.get("tool_input") or {}
  detail=ti.get("file_path") or ti.get("url") or json.dumps(ti)[:100]
  tn=d.get("tool_name") or "tool"
  print((tn + ": " + str(detail))[:160])
except Exception: print("tool approval")' 2>>"$LOG")
  {
    python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' \
      "Approval needed — $summary" | "$(dirname "$0")/desktop-notify.sh"
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
      python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' \
        ":raised_hand: [templates] tool approval waiting — ${summary}" \
        | curl -s -m 10 -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK_URL"
    fi
  } >/dev/null 2>&1 &
  exit 0
fi
verdict=$(claude --model claude-haiku-4-5-20251001 -p "$(cat "$(dirname "$0")/permission-rubric.md")

COMMAND TO EVALUATE:
$cmd" 2>>"$LOG" | head -1)
python3 - "$cmd" "$verdict" >>"$LOG" 2>&1 <<'PYEOF'
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
    # ASK / eval-error → a human prompt is about to appear. The Notification hook
    # does NOT fire for background-agent prompts unless the agent view is open,
    # so ping the maintainer from here (desktop banner + Slack), non-blocking.
    reason=$(printf '%s' "${verdict#ASK: }" | head -c 160)
    snip=$(printf '%s' "$cmd" | tr '\n' ' ' | head -c 120)
    {
      python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' \
        "Approval needed: ${reason:-evaluation error} — ${snip}" \
        | "$(dirname "$0")/desktop-notify.sh"
      if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' \
          ":raised_hand: [templates] command approval waiting — ${reason:-evaluation error}
\`${snip}\`" \
          | curl -s -m 10 -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK_URL"
      fi
    } >/dev/null 2>&1 &
    ;;
esac
exit 0
