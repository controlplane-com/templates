#!/bin/bash
# SHADOW-MODE permission evaluator. Logs what it WOULD decide; never decides.
# Registered on PermissionRequest (fires only for commands no allowlist covered
# and no deterministic layer denied). Async — adds zero latency to the prompt.
# Flip to enforcing only after the maintainer reviews a week of this log.
LOG="$(dirname "$0")/perm-decisions.log"
payload=$(cat)
cmd=$(printf '%s' "$payload" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("tool_input") or {}).get("command","")[:500])
except Exception: print("")' 2>>"$LOG")
[ -z "$cmd" ] && { printf '%s\n' "{\"ts\":\"$(date -u +%FT%TZ)\",\"note\":\"non-command or unparsed event\",\"raw\":$(printf '%s' "$payload" | head -c 300 | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" >>"$LOG"; exit 0; }
verdict=$(claude --model claude-haiku-4-5-20251001 -p "$(cat "$(dirname "$0")/permission-rubric.md")

COMMAND TO EVALUATE:
$cmd" 2>>"$LOG" | head -1)
python3 - "$cmd" "$verdict" >>"$LOG" 2>&1 <<'PYEOF'
import sys, json, datetime
print(json.dumps({"ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"), "mode": "shadow",
                  "command": sys.argv[1], "would_decide": sys.argv[2] or "EVAL-ERROR"}))
PYEOF
exit 0
