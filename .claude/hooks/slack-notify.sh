#!/bin/bash
# Slack incoming webhook for hook events.
#
# Wired to:
#   Notification  -> Claude needs permission / is waiting on input
#   TaskCompleted -> a background task (e.g. a long test-runner) finished
#
# Notification alone is NOT enough: it never fires when a background agent
# finishes, which is exactly the "came back hours later to no ping" case.
#
# Requires SLACK_WEBHOOK_URL in the environment (.claude/settings.local.json "env").
# Failures are logged to .claude/hooks/slack-notify.log rather than swallowed —
# a silent notifier is indistinguishable from one that was never wired up.

LOG="$(dirname "$0")/slack-notify.log"
[ -z "${SLACK_WEBHOOK_URL:-}" ] && { echo "$(date -u +%FT%TZ) skipped: SLACK_WEBHOOK_URL unset" >>"$LOG"; exit 0; }

payload=$(cat)

text=$(printf '%s' "$payload" | python3 -c '
import sys, json, os

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

event = d.get("hook_event_name") or ""
project = os.path.basename(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())

if event == "TaskCompleted":
    desc = d.get("description") or d.get("summary") or d.get("task_id") or "background task"
    status = d.get("status") or "finished"
    body = f":white_check_mark: *Task {status}*: {desc}"
else:
    body = ":robot_face: " + (d.get("message") or "Claude Code needs attention")

print(f"[{project}] {body}")
' 2>>"$LOG")

[ -z "$text" ] && text="[$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")] Claude Code needs attention"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
  -H 'Content-type: application/json' \
  --data "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text")" \
  "$SLACK_WEBHOOK_URL" 2>>"$LOG")

[ "$code" = "200" ] || echo "$(date -u +%FT%TZ) slack post failed: HTTP $code" >>"$LOG"
exit 0
