#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
workers="$root/lib/workers"
claim="$workers/agent-claim.sh"
ask="$workers/agent-ask.sh"
report="$workers/agent-report.sh"
success="$workers/last-success-epoch.sh"
tmp=$(mktemp -d)
holder=
cleanup() {
  touch "$tmp/finish"
  if [ -n "$holder" ]; then wait "$holder" || :; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
export XDG_STATE_HOME="$tmp/state" AGENT_CLAIM_DIR="$tmp/claims"
export AGENT_ASK_DIR="$tmp/asks" AGENT_ASK_TASK="OPS-12" AGENT_ASK_WAIT_SECS=0
export AGENT_REPORT_DIR="$tmp/reports" AGENT_REPORT_DISABLE=1 AGENT_REPORT_TO_SESSION="fixture"
export MANAGER_STATE_DIR="$tmp/batches"
unset AGENT_CLAIM_OWNED AGENT_CLAIM_DEPTH AGENT_REPORT_TO_SOCKET

[ "$("$claim" id-from ops-12.md)" = OPS-12 ]
"$claim" wrap OPS-12 fixture -- sh -c '
  touch "$1/ready"
  while [ ! -e "$1/finish" ]; do sleep 0.05; done
' sh "$tmp" &
holder=$!
for ((i=0; i<100; ++i)); do
  [ ! -f "$tmp/ready" ] || break
  sleep 0.05
done
[ -f "$tmp/ready" ]
[ "$("$claim" reason OPS-12)" = foreign ]
if "$claim" wrap OPS-12 fixture -- touch "$tmp/duplicate" 2>"$tmp/refusal"; then exit 1; fi
[ ! -e "$tmp/duplicate" ]
"$claim" wrap OPS-13 fixture -- touch "$tmp/independent"
[ -e "$tmp/independent" ]
touch "$tmp/finish"
wait "$holder"
holder=
[ "$("$claim" reason OPS-12)" = free ]
(
  . "$claim"
  trap 'touch "$tmp/previous-trap"' EXIT
  agent_claim_hold OPS-13 fixture
  agent_claim_busy OPS-13
)
[ -e "$tmp/previous-trap" ]
[ ! -e "$AGENT_CLAIM_DIR/OPS-13" ]

"$ask" ask "Which schedule?" --default "Keep current hours" | grep -q 'no answer yet'
"$ask" pending "$AGENT_ASK_DIR" | grep -q 'Which schedule?'
"$ask" answer "$AGENT_ASK_DIR" "$AGENT_ASK_TASK" "Use weekends"
[ "$("$ask" wait)" = 'Use weekends' ]
"$ask" pending | grep -q 'no pending asks'
[ "$(AGENT_ASK_TASK=OPS-14 AGENT_ASK_DEADLINE_SECS=0 "$ask" ask 'Continue?' --default 'Stop')" = 'DEFAULT: Stop' ]

printf 'EXPECT: result.md\n' > "$tmp/task"
[ "$("$report" evidence "$tmp" "$tmp/task")" = 'missing(0/1):result.md' ]
touch "$tmp/result.md"
[ "$("$report" send --task OPS-12 --rc 0 --git changed --writes 1 --taskfile "$tmp/task" --cwd "$tmp")" = OK ]
"$report" inbox fixture > "$tmp/inbox"
python3 - "$tmp/inbox" <<'PY'
import json
import sys

with open(sys.argv[1]) as inbox:
    question, expired, completion = map(json.loads, inbox)
assert (question["kind"], question["task"], question["default"]) == ("ask", "OPS-12", "Keep current hours")
assert expired["task"] == "OPS-14"
assert (completion["kind"], completion["verdict"], completion["evidence"]) == ("completion", "OK", "ok(1/1)")
PY
[ "$("$success" verdict "$tmp/task.cache" 60)" = never ]
"$report" progress "$tmp/task.progress" "Checked schedule"
grep -q 'Checked schedule' "$tmp/task.progress"
[ -f "$tmp/task.hb" ]
[ "$("$success" verdict "$tmp/task.cache" 60)" = alive ]
echo 'Worker claims, questions, reports and progress passed.'
