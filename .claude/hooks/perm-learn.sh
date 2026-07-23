#!/bin/bash
# PostToolUse learning hook: when a tool call executes AFTER the evaluator said
# ASK, the human must have approved it — that's a labeled override. Append it
# to perm-overrides.log; at each template ship-close the orchestrator reviews
# the overrides and folds recurring patterns into permission-rubric.md.
# Log-only: this hook never blocks or decides anything.
DIR="$(dirname "$0")"
payload=$(cat)
PERM_LEARN_PAYLOAD="$payload" python3 - "$DIR" <<'PYEOF' 2>>"$DIR/perm-learn.log"
import sys, json, datetime, os

hookdir = sys.argv[1]
try:
    d = json.loads(os.environ["PERM_LEARN_PAYLOAD"])
except Exception:
    sys.exit(0)

ti = d.get("tool_input") or {}
cmd = ti.get("command")
if d.get("tool_name") in (None, "Bash") and cmd:
    subject = cmd
else:
    subject = "TOOL: " + str(d.get("tool_name") or "unknown") + " " + json.dumps(ti)[:2000]

# Find a recent ASK verdict for this exact subject in the decisions log.
declog = os.path.join(hookdir, "perm-decisions.log")
try:
    lines = open(declog).read().splitlines()[-200:]
except Exception:
    sys.exit(0)

hit = None
for line in reversed(lines):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("command") == subject[:4000] and not str(e.get("decision", "")).startswith("ALLOW"):
        hit = e
        break
if not hit:
    sys.exit(0)

ovlog = os.path.join(hookdir, "perm-overrides.log")
# Dedupe: don't record the same subject twice in a row.
try:
    last = open(ovlog).read().splitlines()[-1]
    if json.loads(last).get("command") == subject[:4000]:
        sys.exit(0)
except Exception:
    pass

with open(ovlog, "a") as f:
    f.write(json.dumps({
        "ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "command": subject[:4000],
        "evaluator_said": hit.get("decision"),
        "human": "approved",
    }) + "\n")
PYEOF
exit 0
