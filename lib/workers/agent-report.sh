#!/usr/bin/env bash
# Durable worker reports and optional live notifications.

set -u

_AR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$_AR_HERE/last-success-epoch.sh" ]; then
  . "$_AR_HERE/last-success-epoch.sh"
fi

agent_report_dir() {
  printf '%s\n' "${AGENT_REPORT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-runtime/reports}"
}

_agent_report_batch_dir() {
  printf '%s\n' "${MANAGER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/manager}"
}

# Apply completion to its matching batch item.
agent_report_finalize_batch() {
  local task="${1:-}" ticket="${2:-}" verdict="${3:-}" rc="${4:-}" ts="${5:-}"
  [ -n "$task" ] || return 0
  local dir; dir="$(_agent_report_batch_dir)"
  [ -d "$dir" ] || return 0
  AR_BATCH_DIR="$dir" AR_TASK="$task" AR_TICKET="$ticket" AR_VERDICT="$verdict" \
    AR_RC="$rc" AR_TS="$ts" python3 - <<'PY'
import glob
import json
import os

task = os.environ["AR_TASK"]
ticket = os.environ.get("AR_TICKET", "")
verdict = os.environ.get("AR_VERDICT", "")
terminal = {"done", "failed", "stale"}
for path in glob.glob(os.path.join(os.environ["AR_BATCH_DIR"], "*.json")):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    items = data.get("items")
    if not isinstance(items, list):
        continue
    changed = False
    for it in items:
        if not isinstance(it, dict) or (it.get("status") or "") in terminal:
            continue
        names = {it.get("id"), it.get("task"), it.get("ticket")}
        if task in names or (ticket and ticket in names):
            it["status"] = "done" if verdict == "OK" else "failed"
            it["verdict"] = verdict
            it["rc"] = os.environ.get("AR_RC", "")
            it["finished"] = os.environ.get("AR_TS", "")
            changed = True
    if changed:
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
PY
}

# Reconcile recorded batch items with worker liveness.
agent_report_batch_status() {
  local target="${1:-}" dir; dir="$(_agent_report_batch_dir)"
  if [ -n "$target" ] && [ ! -f "$target" ]; then
    target="$dir/${target%.json}.json"
  fi
  if [ -n "$target" ]; then
    [ -f "$target" ] || { echo "agent-report: no batch state at $target" >&2; return 1; }
  else
    [ -d "$dir" ] || { echo "agent-report: no batch state dir at $dir" >&2; return 1; }
  fi
  AR_BATCH_DIR="$dir" AR_BATCH_FILE="$target" AR_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 - <<'PY'
import glob
import json
import os

def alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    try:
        with open("/proc/%d/stat" % pid, encoding="utf-8") as fh:
            state = fh.read().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    return state != "Z"

target = os.environ.get("AR_BATCH_FILE", "")
paths = [target] if target else sorted(glob.glob(os.path.join(os.environ["AR_BATCH_DIR"], "*.json")))
ts = os.environ["AR_TS"]
for path in paths:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        print("%s: unreadable" % path)
        continue
    items = data.get("items")
    if not isinstance(items, list):
        continue
    batch = data.get("batch") or os.path.basename(path)
    changed = False
    for it in items:
        if not isinstance(it, dict):
            continue
        status = it.get("status") or "?"
        pid = it.get("pid")
        if status == "running" and alive(pid) is False:
            it["status"] = status = "stale"
            it["stale_reason"] = "pid %s not alive at %s" % (pid, ts)
            changed = True
        extra = ""
        if status == "running":
            extra = " pid=%s alive" % pid if alive(pid) else " pid=none (unverifiable)"
        elif status == "stale":
            extra = " (%s)" % it.get("stale_reason", "pid dead")
        print("%s  %-28s %s%s" % (batch, it.get("id") or it.get("ticket") or "?", status, extra))
    if changed:
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
PY
}

# The claude session metadata sidecar carries the human-readable session name,
# which is what makes a record legible in the dispatcher's own transcript.
_agent_report_session_json() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  local f="$HOME/.claude/sessions/$pid.json"
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

_agent_report_pid_from_socket() {
  local sock="${1:-}"
  [ -n "$sock" ] || return 1
  local base="${sock##*/}"
  base="${base%.sock}"
  case "$base" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$base"
}

# Who am I, so a worker I spawn can answer me. Printed as shell exports because
# the consumers are a task state file and a spawned pane's --pre command.
agent_report_origin() {
  local sock="${CLAUDE_CODE_MESSAGING_SOCKET:-}" pid sid name meta
  # My own socket wins over an inherited one: a worker pane that farms out its
  # own sub-tasks is their dispatcher, so those records belong to it, not to
  # whoever started the pane. The inherited address is the fallback for runtimes
  # that bind no socket of their own (grok, cursor, codex).
  if [ -z "$sock" ]; then
    printf 'AGENT_REPORT_TO_SOCKET=%s\n' "${AGENT_REPORT_TO_SOCKET:-}"
    printf 'AGENT_REPORT_TO_SESSION=%s\n' "${AGENT_REPORT_TO_SESSION:-}"
    printf 'AGENT_REPORT_TO_NAME=%s\n' "${AGENT_REPORT_TO_NAME:-}"
    return 0
  fi
  printf 'AGENT_REPORT_TO_SOCKET=%s\n' "$sock"
  sid="${CLAUDE_CODE_SESSION_ID:-}"
  name=""
  if pid="$(_agent_report_pid_from_socket "$sock")" && meta="$(_agent_report_session_json "$pid")"; then
    name="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("name") or ""))' "$meta" 2>/dev/null || true)"
    [ -n "$sid" ] || sid="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("sessionId") or ""))' "$meta" 2>/dev/null || true)"
  fi
  printf 'AGENT_REPORT_TO_SESSION=%s\n' "$sid"
  printf 'AGENT_REPORT_TO_NAME=%s\n' "$name"
}

# The mirror image of origin: declare that there is no one to answer.
#
# A SessionStart hook runs inside the interactive session that triggered it, so a
# daemon started from that hook inherits that session's messaging socket for its
# whole life, and so does every worker it farms — a worker's report then lands
# in a session that never dispatched it, across work and personal context.
# Nothing scans the socket directory; the address is pure env inheritance, so
# severing the env is the whole fix.
#
# The split is who asked. Work a human or another agent dispatched on purpose
# keeps its dispatcher; work a hook or a timer started has none, and its records
# fall through to the durable inbox and the notify escalation below.
agent_report_detach() {
  local v
  for v in $(compgen -v AGENT_REPORT_TO_ 2>/dev/null || true); do
    unset "$v"
  done
  # The session id goes too: always-on.sh rebuilds the reply address from it
  # when AGENT_REPORT_TO_SESSION is empty, which would file a detached batch's
  # records in the triggering session's inbox.
  unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ID
}

# Write the dispatcher identity into the task's own state, at dispatch time.
# The token is deliberately NOT stored: it is a live secret, and both ways of
# obtaining it (inherited env, or the owner-only key file) are available at
# send time without ever putting it on disk here.
agent_report_record_dispatcher() {
  local statefile="$1"
  agent_report_origin > "$statefile"
}

agent_report_load_dispatcher() {
  local statefile="${1:-}"
  [ -n "$statefile" ] && [ -f "$statefile" ] || return 1
  # shellcheck source=/dev/null
  . "$statefile"
}

# rc here must be the MODEL's exit code, not a wrapper's synthesized one:
# farm.sh rewrites a no-op task to exit 1, and NO-WORK vs FAILED is exactly
# the distinction that rewrite would destroy.
agent_report_verdict() {
  local rc="${1:-}" git_state="${2:--}" writes="${3:-0}" flag="${4:-}" ask="${5:-}" offrepo="${6:-0}"
  case "$flag" in
    refused) printf 'REFUSED\n'; return 0 ;;
    skipped) printf 'SKIPPED\n'; return 0 ;;
    limited) printf 'LIMITED\n'; return 0 ;;
    timeout) printf 'TIMEOUT\n'; return 0 ;;
    stood-down) printf 'STOOD-DOWN\n'; return 0 ;;
  esac
  case "$writes" in
    ''|*[!0-9]*) writes=0 ;;
  esac
  if [ "$rc" = "0" ]; then
    if [ "$writes" -eq 0 ] && [ "$git_state" != "changed" ]; then
      # An unanswered .ask means this worker was waiting on input, not
      # producing nothing — NO-WORK would bury the question. NEED does not
      # apply when work happened: a worker that ran its default and shipped
      # grades OK even with the .ask still unanswered.
      if [ "$ask" = "pending" ]; then
        printf 'NEED\n'
        return 0
      fi
      # A task that declared `Deliverable: off-repo` (tickets, posts) is not
      # judgeable by git state or write tools — rc=0 is OK, not NO-WORK.
      if [ "$offrepo" = 1 ]; then
        printf 'OK\n'
        return 0
      fi
      printf 'NO-WORK\n'
      return 0
    fi
    printf 'OK\n'
    return 0
  fi
  printf 'FAILED\n'
}

# Did it produce what the task asked for? A script cannot infer intent, so the
# task file declares it: any `EXPECT: <glob>` line is checked against the cwd.
# No declaration is reported as none-declared rather than silently passing.
agent_report_evidence() {
  local cwd="${1:-.}" taskfile="${2:-}" pat total=0 found=0 missing=""
  [ -n "$taskfile" ] && [ -f "$taskfile" ] || { printf 'none-declared\n'; return 0; }
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    total=$((total + 1))
    # shellcheck disable=SC2086
    if ( cd "$cwd" 2>/dev/null && compgen -G "$pat" >/dev/null 2>&1 ); then
      found=$((found + 1))
    elif [ -z "$missing" ]; then
      missing="$pat"
    fi
  done <<EOF
$(grep -oiE '^[[:space:]]*expect:[[:space:]]*.+$' "$taskfile" 2>/dev/null \
    | sed -E 's/^[[:space:]]*[Ee][Xx][Pp][Ee][Cc][Tt]:[[:space:]]*//' || true)
EOF
  if [ "$total" -eq 0 ]; then
    printf 'none-declared\n'
  elif [ "$found" -eq "$total" ]; then
    printf 'ok(%s/%s)\n' "$found" "$total"
  else
    printf 'missing(%s/%s):%s\n' "$found" "$total" "$missing"
  fi
}

_agent_report_dur() {
  local s="${1:-0}"
  case "$s" in
    ''|*[!0-9]*) printf '?\n'; return 0 ;;
  esac
  if [ "$s" -lt 60 ]; then printf '%ss\n' "$s"; else printf '%sm%02ds\n' "$((s / 60))" "$((s % 60))"; fi
}

# One socket write. Returns non-zero if the dispatcher is unreachable, which is
# what promotes the record to the notify fallback.
agent_report_deliver() {
  local sock="${1:-}" text="${2:-}" from="${3:-farm}" prio="${4:-next}"
  [ -n "$sock" ] || return 1
  [ -S "$sock" ] || return 1
  AGENT_REPORT_SOCK="$sock" AGENT_REPORT_TEXT="$text" AGENT_REPORT_FROM="$from" \
    AGENT_REPORT_PRIO="$prio" python3 - <<'PY'
import glob
import hashlib
import json
import os
import socket
import sys

sock = os.environ["AGENT_REPORT_SOCK"]
text = os.environ["AGENT_REPORT_TEXT"]
sender = os.environ["AGENT_REPORT_FROM"]


def tokens():
    env = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN")
    if env:
        yield env
    digest = hashlib.sha256(os.path.abspath(sock).encode()).hexdigest()
    for path in glob.glob(os.path.join(os.path.expanduser("~/.claude/sessions"), "*.%s.key" % digest)):
        try:
            with open(path, encoding="utf-8") as fh:
                peer = json.load(fh).get("peerToken")
        except (OSError, ValueError):
            continue
        if peer:
            yield peer


def send(token):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(sock)
        frames = []
        if token:
            frames.append({"type": "auth", "token": token})
        frames.append({
            "type": "user",
            "from": sender,
            "priority": os.environ.get("AGENT_REPORT_PRIO", "next"),
            "message": {"role": "user", "content": text},
        })
        s.sendall("".join(json.dumps(f) + "\n" for f in frames).encode())
        s.shutdown(socket.SHUT_WR)
    finally:
        s.close()


candidates = list(tokens())
# Auth is optional on some platforms; an unauthenticated attempt is the last
# resort, never the first, so an authenticated peer is not mislabelled.
candidates.append(None)
for tok in candidates:
    try:
        send(tok)
        raise SystemExit(0)
    except (OSError, socket.timeout):
        continue
raise SystemExit(1)
PY
}

_agent_report_json() {
  python3 - "$@" <<'PY'
import json
import sys

keys = ["kind", "ts", "task", "ticket", "runtime", "verdict", "rc", "duration_s",
        "git", "writes", "bytes", "evidence", "out", "to_session", "to_socket",
        "delivered", "final", "note"]
print(json.dumps(dict(zip(keys, sys.argv[1:]))))
PY
}

_agent_report_ask_json() {
  python3 - "$@" <<'PY'
import json
import sys

keys = ["kind", "ts", "task", "ticket", "question", "default", "deadline",
        "ask", "to_session", "to_socket", "delivered"]
print(json.dumps(dict(zip(keys, sys.argv[1:]))))
PY
}

# The record every completion pushes. Human-readable because it lands in the
# dispatcher's session as a message a model reads, not as a parsed payload.
agent_report_compose() {
  local task="$1" ticket="$2" runtime="$3" verdict="$4" rc="$5" dur="$6" \
    git_state="$7" writes="$8" bytes="$9" evidence="${10}" out="${11}" final="${12}" \
    note="${13:-}"
  printf '[farm] %s  %s  runtime=%s exit=%s dur=%s git=%s writes=%s bytes=%s evidence=%s\n' \
    "$verdict" "${ticket:-$task}" "$runtime" "$rc" "$dur" "$git_state" "$writes" "$bytes" "$evidence"
  printf 'task=%s\n' "$task"
  [ -n "$out" ] && printf 'out=%s\n' "$out"
  case "$verdict" in
    NEED) printf 'This worker exited with an UNANSWERED ask on file — read the .ask next to the .out and answer it (agent-ask.sh answer <dir> <task> "<text>") or run its recorded default.\n' ;;
    NO-WORK) printf 'This task exited 0 but changed no git state and called no write tool — it produced nothing.\n' ;;
    REFUSED) printf 'This task never ran: the claim was held by another live session.\n' ;;
    SKIPPED) printf 'This task never ran: its required execution environment is unavailable; read the task output for the exact requirement.\n' ;;
    LIMITED) printf 'This task never ran to completion: no usable runtime / a live rate limit.\n' ;;
    TIMEOUT) printf 'farm killed this worker: it hit the wall-clock cap or stopped making progress. Partial output may still be in the .out.\n' ;;
    STOOD-DOWN) printf 'farm stood this worker down: the ticket is closed and the work is already on origin/main — not a model that produced nothing.\n' ;;
  esac
  if [ -n "$note" ]; then
    if [ "$verdict" = "TIMEOUT" ]; then
      printf 'killed: %s\n' "$note"
    else
      printf 'note: %s\n' "$note"
    fi
  fi
  if [ -n "$final" ]; then
    printf -- '--- worker final message (truncated) ---\n%s\n' "$final"
  fi
}

_agent_report_tail() {
  local f="${1:-}" n="${2:-1500}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  if [ "${f##*.}" = out ] && [ -s "${f%.out}.final" ]; then
    f="${f%.out}.final"
  fi
  tail -c "$n" "$f" 2>/dev/null | tr -d '\000' || true
}

agent_report_send() {
  local task="" ticket="" runtime="-" rc="0" git_state="-" writes="0" bytes="0" \
    flag="" outfile="" taskfile="" cwd="." dur_s="0" sock="" sid="" name="" statefile="" \
    note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)       task="$2"; shift 2 ;;
      --ticket)     ticket="$2"; shift 2 ;;
      --runtime)    runtime="$2"; shift 2 ;;
      --rc)         rc="$2"; shift 2 ;;
      --git)        git_state="$2"; shift 2 ;;
      --writes)     writes="$2"; shift 2 ;;
      --bytes)      bytes="$2"; shift 2 ;;
      --flag)       flag="$2"; shift 2 ;;
      --out)        outfile="$2"; shift 2 ;;
      --taskfile)   taskfile="$2"; shift 2 ;;
      --cwd)        cwd="$2"; shift 2 ;;
      --duration)   dur_s="$2"; shift 2 ;;
      --dispatcher) statefile="$2"; shift 2 ;;
      --note)       note="$2"; shift 2 ;;
      *) echo "agent-report: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -n "$task" ] || { echo "agent-report: --task is required" >&2; return 2; }

  if [ -n "$statefile" ] && [ -f "$statefile" ]; then
    # shellcheck source=/dev/null
    . "$statefile"
  fi
  sock="${AGENT_REPORT_TO_SOCKET:-}"
  sid="${AGENT_REPORT_TO_SESSION:-}"
  name="${AGENT_REPORT_TO_NAME:-}"

  # Evidence, not model judgment: an unanswered ask is the .ask farm's worker
  # filed next to its .out, with no .answer beside it (agent-ask.sh).
  local ask_state=""
  case "$outfile" in
    *.out)
      if [ -f "${outfile%.out}.ask" ] && [ ! -f "${outfile%.out}.answer" ]; then
        ask_state=pending
      fi
      ;;
  esac

  local verdict evidence dur final text offrepo=0
  if [ -n "$taskfile" ] && [ -f "$taskfile" ] \
      && grep -qiE '^Deliverable:[[:space:]]*off-repo[[:space:]]*$' "$taskfile"; then
    offrepo=1
  fi
  verdict="$(agent_report_verdict "$rc" "$git_state" "$writes" "$flag" "$ask_state" "$offrepo")"
  evidence="$(agent_report_evidence "$cwd" "$taskfile")"
  dur="$(_agent_report_dur "$dur_s")"
  final="$(_agent_report_tail "$outfile" "${AGENT_REPORT_TAIL:-1500}")"
  text="$(agent_report_compose "$task" "$ticket" "$runtime" "$verdict" "$rc" "$dur" \
    "$git_state" "$writes" "$bytes" "$evidence" "$outfile" "$final" "$note")"

  local delivered=no
  # A test suite shells out to farm.sh with the operator's own socket still in
  # env, and every stub task would then land in the session running the suite.
  # Test suites set this; nothing in the real path does.
  if [ "${AGENT_REPORT_DISABLE:-0}" = "1" ]; then
    sock=""
  elif agent_report_deliver "$sock" "$text" "farm/${ticket:-$task}" 2>/dev/null; then
    delivered=yes
  fi

  # Written on every send, not only on failure: a socket write that succeeds
  # still tells us nothing about the receiving session's inbound mode, so this
  # file is the only durable proof of what was reported.
  local dir inbox
  dir="$(agent_report_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  inbox="$dir/${sid:-nodispatcher}.jsonl"
  _agent_report_json completion "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task" "$ticket" "$runtime" \
    "$verdict" "$rc" "$dur_s" "$git_state" "$writes" "$bytes" "$evidence" "$outfile" \
    "$sid" "$sock" "$delivered" "$final" "$note" >> "$inbox" 2>/dev/null || true

  if [ "${AGENT_REPORT_DISABLE:-0}" != "1" ]; then
    agent_report_finalize_batch "$task" "$ticket" "$verdict" "$rc" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
  fi

  if [ "$delivered" = no ] && [ "${AGENT_REPORT_DISABLE:-0}" != "1" ]; then
    printf 'agent-report: dispatcher unreachable (%s) — record in %s\n' \
      "${name:-${sid:-no session recorded}}" "$inbox" >&2
    _agent_report_notify_batched "$text" "$inbox"
  fi
  printf '%s\n' "$verdict"
}

# A worker's mid-run question (agent-ask.sh), pushed like a completion: to the
# dispatcher's socket AND appended kind=ask to the durable inbox on every send.
# No notify escalation — the --default the worker filed is what guarantees
# progress, and socketless dispatchers sweep `agent-ask.sh pending` instead.
agent_report_ask() {
  local task="" ticket="" question="" default="" deadline="" askfile="" statefile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)       task="$2"; shift 2 ;;
      --ticket)     ticket="$2"; shift 2 ;;
      --question)   question="$2"; shift 2 ;;
      --default)    default="$2"; shift 2 ;;
      --deadline)   deadline="$2"; shift 2 ;;
      --ask)        askfile="$2"; shift 2 ;;
      --dispatcher) statefile="$2"; shift 2 ;;
      *) echo "agent-report: unknown arg $1" >&2; return 2 ;;
    esac
  done
  [ -n "$task" ] || { echo "agent-report: --task is required" >&2; return 2; }
  [ -n "$question" ] && [ -n "$default" ] || {
    echo 'agent-report: ask requires --question and --default' >&2; return 2;
  }

  if [ -z "$askfile" ]; then
    if [ -n "${AGENT_ASK_DIR:-}" ]; then
      askfile="$AGENT_ASK_DIR/$task.ask"
    elif [ -n "$statefile" ]; then
      askfile="$(dirname "$statefile")/$task.ask"
    else
      echo 'agent-report: ask requires --ask, AGENT_ASK_DIR, or --dispatcher' >&2
      return 2
    fi
  fi
  case "$askfile" in
    *.ask) ;;
    *) echo 'agent-report: --ask must name a .ask file' >&2; return 2 ;;
  esac
  local askdir askname ask_tmp
  askdir="$(dirname "$askfile")"
  mkdir -p "$askdir" || return 1
  askdir="$(cd "$askdir" && pwd)" || return 1
  askname="$(basename "$askfile" .ask)"
  askfile="$askdir/$askname.ask"
  statefile="${statefile:-$askdir/$task.dispatcher}"

  if [ -n "$statefile" ] && [ -f "$statefile" ]; then
    # shellcheck source=/dev/null
    . "$statefile"
  fi
  local sock="${AGENT_REPORT_TO_SOCKET:-}" sid="${AGENT_REPORT_TO_SESSION:-}"

  # The public report CLI must file the ask before advertising an answer command.
  ask_tmp="$(mktemp "$askfile.tmp.XXXXXX")" || return 1
  if ! _agent_report_ask_json ask "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task" "$ticket" \
      "$question" "$default" "$deadline" "$askfile" "$sid" "$sock" no > "$ask_tmp" \
      || ! mv "$ask_tmp" "$askfile"; then
    rm -f "$ask_tmp"
    return 1
  fi

  local dl_iso="$deadline"
  case "$deadline" in
    ''|*[!0-9]*) ;;
    *) dl_iso="$(date -u -d "@$deadline" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$deadline")" ;;
  esac
  local text
  text="$(printf '[ask] %s needs an answer (deadline %s)\nquestion: %s\ndefault: %s\nanswer with: %q answer %q %q "<text>"\n' \
    "${ticket:-$task}" "${dl_iso:-none}" "$question" "$default" \
    "$_AR_HERE/agent-ask.sh" "$askdir" "$askname")"

  local delivered=no
  if [ "${AGENT_REPORT_DISABLE:-0}" = "1" ]; then
    sock=""
  elif agent_report_deliver "$sock" "$text" "ask/${ticket:-$task}" 2>/dev/null; then
    delivered=yes
  fi

  # Same invariant as send: the inbox is written on EVERY send, because a
  # socket write proves delivery to an inbox, never that anyone read it.
  local dir inbox
  dir="$(agent_report_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  inbox="$dir/${sid:-nodispatcher}.jsonl"
  _agent_report_ask_json ask "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task" "$ticket" \
    "$question" "$default" "$dl_iso" "$askfile" "$sid" "$sock" "$delivered" \
    >> "$inbox" 2>/dev/null || true

  if [ "$delivered" = no ] && [ "${AGENT_REPORT_DISABLE:-0}" != "1" ]; then
    printf 'agent-report: dispatcher unreachable — ask recorded in %s; sweep with `agent-ask.sh pending`\n' \
      "$inbox" >&2
  fi
}

_agent_report_progress_json() {
  python3 - "$@" <<'PY'
import json
import sys

keys = ["kind", "ts", "task", "line", "to_session", "to_socket", "delivered"]
print(json.dumps(dict(zip(keys, sys.argv[1:]))))
PY
}

# Progress arriving after a terminal verdict stays in the durable inbox.
_agent_report_farm_exited() {
  local pfile="${1:-}" task="${2:-}" farmlog
  farmlog="$(dirname "$pfile")/farm.log"
  [ -n "$task" ] && [ -f "$farmlog" ] || return 1
  grep "^farm: $task " "$farmlog" 2>/dev/null | grep -q "exit="
}

# A worker's mid-run heartbeat: the dispatcher expects a push at least every
# minute. Appends to the task's .progress file — the durable contract, written
# unconditionally — then pushes the same line to the dispatcher over the
# completion socket, priority=later so a heartbeat never queues ahead of real
# work. The socket is best-effort: the dispatcher gets at most one delivery per
# task per AGENT_REPORT_PROGRESS_THROTTLE seconds (default 30; excess lines
# still land in the file), and a dead or missing socket exits 0 — a heartbeat
# must never break the worker it reports on.
agent_report_progress() {
  local pfile="${1:-}" line="${2:-}"
  if [ -z "$pfile" ] || [ -z "$line" ]; then
    echo 'usage: agent-report.sh progress <task.progress> "<status>"' >&2
    return 2
  fi
  local base="${pfile%.progress}" task
  task="$(basename "$base")"
  printf '%s %s\n' "$(date -u +%H:%M)" "$line" >> "$pfile" 2>/dev/null || true
  if type last_success_write >/dev/null 2>&1; then
    last_success_write "$(last_success_farm_cache "$pfile")"
  fi

  local throttle="${AGENT_REPORT_PROGRESS_THROTTLE:-30}" stamp="$base.throttle" now last
  now="$(date +%s)"
  last="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
  [ $((now - last)) -ge "$throttle" ] || return 0
  touch "$stamp" 2>/dev/null || true
  # farm.sh _farm_progress_token reads $base.hb mtime as a liveness signal.
  touch "$base.hb" 2>/dev/null || true

  if [ -f "$base.dispatcher" ]; then
    # shellcheck source=/dev/null
    . "$base.dispatcher"
  fi
  local sock="${AGENT_REPORT_TO_SOCKET:-}" sid="${AGENT_REPORT_TO_SESSION:-}"

  local delivered=no text="[progress] ${task}: $line"
  if [ "${AGENT_REPORT_DISABLE:-0}" = "1" ]; then
    sock=""
  elif _agent_report_farm_exited "$pfile" "$task"; then
    # Verdict is in: inbox below still records the line; socket must not.
    :
  elif agent_report_deliver "$sock" "$text" "progress/$task" later 2>/dev/null; then
    delivered=yes
  fi

  # Same invariant as send/ask: the inbox is the durable copy of every push.
  local dir inbox
  dir="$(agent_report_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  inbox="$dir/${sid:-nodispatcher}.jsonl"
  _agent_report_progress_json progress "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task" \
    "$line" "$sid" "$sock" "$delivered" >> "$inbox" 2>/dev/null || true
  return 0
}

_AR_NOTIFY_SESSION_ID="farm-done"
_agent_report_notify_post() {
  local text="$1" jobdir="$2" notify="$3"
  [ -x "$notify" ] || return 0
  [ "${AGENT_REPORT_NO_NOTIFY:-0}" = "1" ] && return 0
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"last_assistant_message":sys.argv[2],"message":sys.argv[2]}))' \
    "${_AR_NOTIFY_SESSION_ID}" "$text" 2>/dev/null \
    | AGENT_JOB_DIR="$jobdir" "$notify" stop >/dev/null 2>&1 || true
}

# Coalesce detached completions within the notification window.
_agent_report_notify_batched() {
  local text="$1" inbox="$2" notify="${AGENT_REPORT_NOTIFY_CMD:-$_AR_HERE/agent-notify.sh}"
  [ -x "$notify" ] || return 0

  local batch_dir="${AGENT_REPORT_BATCH_DIR:-$(agent_report_dir)/notify-batch}"
  mkdir -p "$batch_dir" 2>/dev/null || return 0

  local inbox_base="$(basename "$inbox" .jsonl)"
  local batch_file="$batch_dir/${inbox_base}.pending"
  local batch_ts_file="$batch_dir/${inbox_base}.ts"
  local batch_lock="$batch_dir/${inbox_base}.lock"
  local batch_window="${AGENT_REPORT_BATCH_WINDOW:-600}"  # 10 min default
  local batch_threshold="${AGENT_REPORT_BATCH_THRESHOLD:-5}"  # 5 completions

  local now="$(date +%s)"

  # Check for orphan pending from a prior window that expired
  if [ -f "$batch_ts_file" ]; then
    local batch_start="$(cat "$batch_ts_file" 2>/dev/null || echo "$now")"
    local batch_age=$((now - batch_start))
    if [ "$batch_age" -ge "$batch_window" ] && [ -f "$batch_file" ]; then
      # Flush the orphan before processing this new record
      if mkdir "$batch_lock" 2>/dev/null; then
        local orphan_count orphan_text sep_count
        sep_count=$(grep -c '^---$' "$batch_file" 2>/dev/null || true)
        orphan_count=$((sep_count + 1))
        if [ "$orphan_count" -eq 1 ]; then
          orphan_text="$(cat "$batch_file")"
        else
          orphan_text="[agent-report] Batched farm completions ($orphan_count records):

$(cat "$batch_file")"
        fi

        local jobdir="${AGENT_JOB_DIR:-$batch_dir}"
        _agent_report_notify_post "$orphan_text" "$jobdir" "$notify"
        rm -f "$batch_file" "$batch_ts_file"
        rmdir "$batch_lock" 2>/dev/null || true
      fi
    fi
  fi

  # First record in a fresh batch: notify immediately, mark batch window start
  if [ ! -f "$batch_file" ]; then
    local jobdir="${AGENT_JOB_DIR:-$batch_dir}"
    _agent_report_notify_post "$text" "$jobdir" "$notify"
    # Mark the start of a new batching window (empty pending, timestamp set)
    touch "$batch_file"
    printf '%s\n' "$now" > "$batch_ts_file"
    return 0
  fi

  # Subsequent records: append to pending
  if [ -s "$batch_file" ]; then
    printf '\n---\n\n' >> "$batch_file"
  fi
  printf '%s\n' "$text" >> "$batch_file"

  # Count pending records (excludes the first immediate-notify item)
  local sep_count batch_count
  sep_count=$(grep -c '^---$' "$batch_file" 2>/dev/null || true)
  batch_count=$((sep_count + 1))

  # Re-read timestamp for this check
  local batch_start="$(cat "$batch_ts_file" 2>/dev/null || echo "$now")"
  local batch_age=$((now - batch_start))

  # Flush if window expired or threshold reached
  if [ "$batch_age" -ge "$batch_window" ] || [ "$batch_count" -ge "$batch_threshold" ]; then
    if mkdir "$batch_lock" 2>/dev/null; then
      local jobdir="${AGENT_JOB_DIR:-$batch_dir}"
      local batch_text line_count
      line_count="$(wc -l < "$batch_file")"
      if [ "$line_count" -gt 50 ]; then
        batch_text="[agent-report] Batched farm completions ($batch_count records):

$(head -50 "$batch_file")
... truncated, see inbox: $inbox"
      else
        batch_text="[agent-report] Batched farm completions ($batch_count records):

$(cat "$batch_file")"
      fi

      _agent_report_notify_post "$batch_text" "$jobdir" "$notify"

      rm -f "$batch_file" "$batch_ts_file"
      rmdir "$batch_lock" 2>/dev/null || true
    fi
  fi
}

_agent_report_notify() {
  local text="$1" inbox="$2" notify="${AGENT_REPORT_NOTIFY_CMD:-$_AR_HERE/agent-notify.sh}"
  local jobdir="${AGENT_JOB_DIR:-$(agent_report_dir)/notify}"
  mkdir -p "$jobdir" 2>/dev/null || true
  _agent_report_notify_post "$text" "$jobdir" "$notify"
}

# Sourced by farm.sh / dispatch.sh; run directly for the CLI above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    origin)   agent_report_origin ;;
    verdict)  shift; agent_report_verdict "$@" ;;
    evidence) shift; agent_report_evidence "$@" ;;
    send)     shift; agent_report_send "$@" ;;
    ask)      shift; agent_report_ask "$@" ;;
    progress) shift; agent_report_progress "$@" ;;
    batch-status) shift; agent_report_batch_status "${1:-}" ;;
    inbox)
      shift
      f="$(agent_report_dir)/${1:-${CLAUDE_CODE_SESSION_ID:-nodispatcher}}.jsonl"
      [ -f "$f" ] && cat "$f" || echo "(no reports for ${1:-this session})"
      ;;
    *) echo "usage: agent-report.sh origin|verdict <rc> <git> <writes> [flag] [ask]|evidence <cwd> <task>|send --task N [...]|ask --task N [...]|progress <task.progress> <status>|inbox [session]|batch-status [file|slug]" >&2; exit 2 ;;
  esac
fi
