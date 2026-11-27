#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
debrief="$root/lib/learning/session-debrief.sh"
reader="$root/lib/learning/session-transcripts.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SESSION_TRANSCRIPTS_HOME="$tmp" SESSION_TRANSCRIPTS_CLOUD_ROOT="$tmp/cloud"
export SESSION_DEBRIEF_CACHE="$tmp/state" SESSION_DEBRIEF_MIN_LINES=1
mkdir -p "$tmp/.claude/projects/test"
record="$tmp/.claude/projects/test/session.jsonl"
printf '{"type":"user","cwd":"%s","message":{"content":"Use the submitted receipt."}}\n' "$tmp/project" > "$record"
"$reader" list --workspace "$tmp/project" | grep -q 'Use the submitted receipt'
test -z "$("$reader" list --workspace "$tmp/sibling")"

export SESSION_DEBRIEF_STUB_OUTPUT='{"learning":"Require receipts","why":"Verified delivery needs one","where":"AGENTS.md"}'
"$debrief" run "$record"
"$debrief" queue > "$tmp/snapshot"
export SESSION_DEBRIEF_STUB_OUTPUT='{"learning":"Verify publish","why":"Upload can fail","where":"release skill"}'
"$debrief" run "$record"
"$debrief" acknowledge "$tmp/snapshot"
test "$("$debrief" queue)" = "$SESSION_DEBRIEF_STUB_OUTPUT"
"$debrief" acknowledge "$tmp/snapshot"
test "$("$debrief" queue)" = "$SESSION_DEBRIEF_STUB_OUTPUT"
unset SESSION_DEBRIEF_STUB_OUTPUT
MANAGER_CLI=false "$debrief" run "$record"
"$debrief" queue | grep -q '"status":"deferred"'
