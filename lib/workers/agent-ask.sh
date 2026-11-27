#!/usr/bin/env bash
# Worker questions, bounded waits and atomic replies.

AGENT_ASK_DEADLINE_SECS="${AGENT_ASK_DEADLINE_SECS:-600}"
AGENT_ASK_WAIT_SECS="${AGENT_ASK_WAIT_SECS:-90}"

_AA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$_AA_HERE/agent-report.sh" ]; then
  . "$_AA_HERE/agent-report.sh"
else
  # A standalone worker can still use the file protocol.
  agent_report_ask() { :; }
fi

_agent_ask_ticket() {
  local s="${1:-}" ticket upcase_s
  # Lowercase matches only in a filename-shaped candidate (no '/', no space) —
  # same rule as agent_claim_id_from, so a task's report and its claim never key
  # off different ids. Paths and prose stay uppercase-only.
  if printf '%s\n' "$s" | grep -qE '[/[:space:]]'; then
    ticket="$(printf '%s\n' "$s" | grep -oE '(^|[^A-Za-z0-9_-])[A-Z]{2,10}-[0-9]+' | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)"
  else
    upcase_s="$(printf '%s\n' "$s" | tr '[:lower:]' '[:upper:]')"
    ticket="$(printf '%s\n' "$upcase_s" | grep -oE '(^|[^A-Z0-9_-])[A-Z]{2,10}-[0-9]+' | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)"
  fi
  printf '%s' "$ticket"
}

_agent_ask_base() {
  [ -n "${AGENT_ASK_DIR:-}" ] && [ -n "${AGENT_ASK_TASK:-}" ] || return 1
  printf '%s/%s\n' "$AGENT_ASK_DIR" "$AGENT_ASK_TASK"
}

_agent_ask_field() {
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' \
    "$1" "$2" 2>/dev/null
}

_agent_ask_write() {
  local base="$1" question="$2" default="$3" now deadline secs
  now="$(date +%s)"
  secs="${AGENT_ASK_DEADLINE_SECS%.*}"
  case "$secs" in ''|*[!0-9]*) secs=600 ;; esac
  deadline=$((now + secs))
  AA_Q="$question" AA_D="$default" python3 - "$base.ask" "$AGENT_ASK_TASK" \
    "$(_agent_ask_ticket "$AGENT_ASK_TASK")" "$now" "$deadline" <<'PY'
import json
import os
import sys
import time

path, task, ticket, now, deadline = sys.argv[1:6]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(now))),
    "task": task,
    "ticket": ticket,
    "question": os.environ["AA_Q"],
    "default": os.environ["AA_D"],
    "deadline": int(deadline),
}
tmp = "%s.tmp.%d" % (path, os.getpid())
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(rec, fh)
    fh.write("\n")
os.replace(tmp, path)
PY
}

agent_ask_ask() {
  local question="" default=""
  while [ $# -gt 0 ]; do
    case "$1" in
      # shift, not shift 2: a trailing valueless --default must not spin the loop.
      --default) default="${2:-}"; shift; [ $# -gt 0 ] && shift || true ;;
      *)
        if [ -z "$question" ]; then question="$1"; else question="$question $1"; fi
        shift
        ;;
    esac
  done
  if [ -z "$question" ]; then
    echo 'agent-ask: REFUSED — usage: agent-ask.sh ask "<question>" --default "<action if unanswered>"' >&2
    return 2
  fi
  if [ -z "$default" ]; then
    echo 'agent-ask: REFUSED — an ask REQUIRES --default "<action if unanswered>"; the default is what guarantees a question never parks the batch.' >&2
    return 2
  fi
  local base
  base="$(_agent_ask_base)" || {
    echo 'agent-ask: REFUSED — AGENT_ASK_DIR / AGENT_ASK_TASK must be set before asking or waiting.' >&2
    return 2
  }
  mkdir -p "$AGENT_ASK_DIR"
  _agent_ask_write "$base" "$question" "$default" || return 1
  agent_report_ask --task "$AGENT_ASK_TASK" \
    --ticket "$(_agent_ask_ticket "$AGENT_ASK_TASK")" \
    --question "$question" --default "$default" \
    --deadline "$(_agent_ask_field "$base.ask" deadline)" \
    --ask "$base.ask" --dispatcher "$base.dispatcher" >/dev/null || true
  agent_ask_wait
}

# Answer found / deadline passed / budget spent all exit 0: the worker must
# keep going on ALL of them — only a malformed call is an error.
agent_ask_wait() {
  local base askf ansf hbf default deadline waited=0 now budget
  base="$(_agent_ask_base)" || {
    echo 'agent-ask: REFUSED — AGENT_ASK_DIR / AGENT_ASK_TASK must be set before asking or waiting.' >&2
    return 2
  }
  askf="$base.ask"; ansf="$base.answer"; hbf="$base.hb"
  [ -f "$askf" ] || {
    echo "agent-ask: no ask on file at $askf — run agent-ask.sh ask first." >&2
    return 2
  }
  default="$(_agent_ask_field "$askf" default)"
  deadline="$(_agent_ask_field "$askf" deadline)"
  case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
  budget="${AGENT_ASK_WAIT_SECS%.*}"
  case "$budget" in ''|*[!0-9]*) budget=90 ;; esac
  while :; do
    if [ -f "$ansf" ]; then
      cat "$ansf"
      return 0
    fi
    now="$(date +%s)"
    if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      printf 'DEFAULT: %s\n' "$default"
      return 0
    fi
    if [ "$waited" -ge "$budget" ]; then
      printf 'no answer yet — run `agent-ask.sh wait` again or execute your default: %s\n' "$default"
      return 0
    fi
    touch "$hbf"
    sleep 1
    waited=$((waited + 1))
  done
}

agent_ask_answer() {
  local dir="${1:-}" task="${2:-}" text="${3:-}"
  if [ -z "$dir" ] || [ -z "$task" ] || [ -z "$text" ]; then
    echo 'usage: agent-ask.sh answer <outdir> <task> "<text>"' >&2
    return 2
  fi
  [ -f "$dir/$task.ask" ] || {
    echo "agent-ask: no ask on file at $dir/$task.ask — nothing is waiting for this answer." >&2
    return 2
  }
  local tmp="$dir/.$task.answer.tmp.$$"
  printf '%s\n' "$text" > "$tmp" && mv "$tmp" "$dir/$task.answer"
}

agent_ask_pending() {
  local dir="${1:-${AGENT_ASK_DIR:-}}" f n=0 task q d dl state now
  [ -n "$dir" ] || {
    echo 'usage: agent-ask.sh pending <dir> (or set AGENT_ASK_DIR)' >&2
    return 2
  }
  now="$(date +%s)"
  for f in "$dir"/*.ask; do
    [ -f "$f" ] || continue
    [ -f "${f%.ask}.answer" ] && continue
    n=$((n + 1))
    task="$(_agent_ask_field "$f" task)"
    q="$(_agent_ask_field "$f" question)"
    d="$(_agent_ask_field "$f" default)"
    dl="$(_agent_ask_field "$f" deadline)"
    state=waiting
    case "$dl" in
      ''|*[!0-9]*) ;;
      *) [ "$now" -ge "$dl" ] && state=expired ;;
    esac
    printf '%s\t%s\t%s\tquestion: %s\tdefault: %s\n' "$f" "${task:-?}" "$state" "$q" "$d"
  done
  [ "$n" -gt 0 ] || printf '(no pending asks in %s)\n' "$dir"
}

agent_ask_help() {
  cat <<'EOF'
Worker questions and replies

Set AGENT_ASK_DIR to a shared output directory and AGENT_ASK_TASK to the task name.
Post a question with a default action.

  agent-ask.sh ask "<question>" --default "<action>"
  agent-ask.sh pending [directory]
  agent-ask.sh answer <directory> <task> "<reply>"
  agent-ask.sh wait

The worker waits up to AGENT_ASK_WAIT_SECS (default 90) per call. Use wait
to poll the same question again. At AGENT_ASK_DEADLINE_SECS (default 600)
the command prints DEFAULT followed by the action. An answer prints verbatim.
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}" in
    ask) shift; agent_ask_ask "$@" ;;
    wait) shift; agent_ask_wait "$@" ;;
    answer) shift; agent_ask_answer "$@" ;;
    pending) shift; agent_ask_pending "$@" ;;
    help|--help|-h) agent_ask_help ;;
    *)
      echo 'usage: agent-ask.sh ask "<question>" --default "<action>" | wait | answer <outdir> <task> "<text>" | pending [dir] | help' >&2
      exit 2
      ;;
  esac
fi
