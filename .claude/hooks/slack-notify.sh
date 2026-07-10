#!/bin/bash
# Notification hook -> Slack incoming webhook.
# Fires when Claude Code needs permission or is waiting for input.
# Requires SLACK_WEBHOOK_URL in the environment (set it in .claude/settings.local.json "env").
[ -z "${SLACK_WEBHOOK_URL:-}" ] && exit 0

payload=$(cat)
msg=$(printf '%s' "$payload" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get("message") or "Claude Code needs attention")
except Exception:
    print("Claude Code needs attention")' 2>/dev/null)

text=":robot_face: *Claude Code* [$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")]: ${msg}"

curl -s -m 5 -X POST -H 'Content-type: application/json' \
  --data "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text")" \
  "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
exit 0
