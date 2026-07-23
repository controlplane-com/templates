#!/bin/bash
# Notification hook: macOS banner + sound when Claude Code needs attention
# (permission prompt waiting / idle waiting for input). Complements slack-notify.sh.
payload=$(cat)
msg=$(printf '%s' "$payload" | jq -r '.message // "Claude Code needs your attention"' 2>/dev/null)
[ -z "$msg" ] && msg="Claude Code needs your attention"

NOTIFIER="$HOME/Applications/Claude Notifier.app/Contents/MacOS/terminal-notifier"
if [ -x "$NOTIFIER" ]; then
  "$NOTIFIER" -title "Claude Code" -subtitle "templates pipeline" -message "$msg" -sound Glass >/dev/null 2>&1
else
  # fallback: plain osascript (shows as Script Editor)
  osascript - "$msg" <<'EOF' >/dev/null 2>&1
on run argv
  display notification (item 1 of argv) with title "Claude Code" subtitle "templates pipeline" sound name "Glass"
end run
EOF
fi
exit 0
