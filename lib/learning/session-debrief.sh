#!/usr/bin/env bash
set -u
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="${SESSION_DEBRIEF_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
workspace_key="$(python3 -c 'import hashlib, os, sys; print(hashlib.sha256(os.fsencode(os.path.realpath(sys.argv[1]))).hexdigest())' "$workspace")"
CACHE_DIR="${SESSION_DEBRIEF_CACHE:-${XDG_STATE_HOME:-$HOME/.local/state}/manager/learning/$workspace_key}"
QUEUE="$CACHE_DIR/queue.jsonl"
LOG="$CACHE_DIR/run.log"
MIN_LINES="${SESSION_DEBRIEF_MIN_LINES:-40}"
mkdir -p "$CACHE_DIR" || exit 1
export SESSION_DEBRIEF_CACHE="$CACHE_DIR"
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
_queue_py() { QUEUE="$QUEUE" LOG="$LOG" python3 "$HERE/debrief-queue.py" "$@"; }
_transcript_from_stdin() { python3 "$HERE/hook-transcript.py"; }

_digest_for() {
  local transcript="$1" digest
  digest="$CACHE_DIR/digests/$(printf '%s' "$transcript" | cksum | cut -d' ' -f1).txt"
  mkdir -p "$CACHE_DIR/digests"
  if python3 "$HERE/session-transcripts.py" extract --max-chars 4000 "$transcript" > "$digest" 2>>"$LOG" \
      && [ -s "$digest" ]; then
    printf '%s\n' "$digest"
  else
    rm -f "$digest"
    printf '%s\n' "$transcript"
  fi
}

_prompt_for() {
  cat <<EOF
Read the agent session transcript at $1.
It is a condensed text file (USER:/ASST: lines, tool output removed) when the
path ends in .txt; do not go looking for the raw JSONL.

Extract ONLY durable learnings: user corrections, conventions established by
evidence, and facts that would change a future decision. Exclude routine
status updates, individual business records, and existing instructions.

For each learning output one JSON object on its own line with exactly these
keys: "learning" (one sentence), "why" (the receipt — the quote, command, or
measurement it came from), "where" (AGENTS.md, a project context file, or a
skill name). Output nothing else. If the session taught nothing durable, output
nothing at all.
EOF
}

run_debrief() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -f "$transcript" ] || { log "no transcript: '${transcript:-}'"; return 0; }

  local lines; lines=$(wc -l < "$transcript" 2>/dev/null || echo 0)
  if [ "$lines" -lt "$MIN_LINES" ]; then
    log "skip (too short: $lines lines) $transcript"; return 0
  fi

  local rt out digest
  local -a run
  digest="$(_digest_for "$transcript")"
  log "debrief input $digest"
  if [ -n "${SESSION_DEBRIEF_STUB_OUTPUT+x}" ]; then
    rt="${SESSION_DEBRIEF_STUB_RUNTIME:-stub}"
    out="$SESSION_DEBRIEF_STUB_OUTPUT"
  else
    if [ -n "${SESSION_DEBRIEF_RUNTIME:-}" ]; then
      # shellcheck disable=SC1090
      . "$SESSION_DEBRIEF_RUNTIME" || return 1
      rt="$(agent_runtime_pick)" || { _queue_py append-deferred "$transcript"; return; }
      run=(agent_runtime_run "$rt")
    else
      rt=manager
      run=("${MANAGER_CLI:-$HERE/../../manager}" run)
    fi
    if ! out="$(SESSION_DEBRIEF_ACTIVE=1 "${run[@]}" "$(_prompt_for "$digest")" 2>>"$LOG")"; then
      log "extraction failed; retaining $transcript for the next sweep"
      _queue_py append-deferred "$transcript"
      return
    fi
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | _queue_py append || return
  fi
  log "debrief finished (runtime=$rt)"
}

case "${1:-hook}" in
  hook)
    [ -n "${SESSION_DEBRIEF_ACTIVE:-}" ] && exit 0
    transcript="$(_transcript_from_stdin)"
    [ -n "$transcript" ] || { log "hook fired with no transcript path"; exit 0; }
    if ! _queue_py claim "$transcript"; then
      log "skip (already debriefed) $transcript"; exit 0
    fi
    if [ -n "${SESSION_DEBRIEF_FOREGROUND:-}" ]; then
      "$0" run "$transcript"
    else
      nohup "$0" run "$transcript" >/dev/null 2>&1 </dev/null &
    fi
    ;;
  run) shift; run_debrief "${1:-}" ;;
  queue) _queue_py queue ;;
  acknowledge) _queue_py acknowledge "${2:?Supply a queue snapshot file}" ;;
  delete-processed)
    [ -n "${2:-}" ] || { echo "usage: session-debrief.sh delete-processed <n>" >&2; exit 2; }
    _queue_py delete-processed "$2"
    ;;
  *) echo "usage: session-debrief.sh hook|run <transcript>|queue|acknowledge <snapshot>|delete-processed <n>" >&2; exit 2 ;;
esac
