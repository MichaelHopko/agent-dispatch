#!/usr/bin/env bash
# Exclusive task claims with bounded inheritance.

AGENT_CLAIM_DIR="${AGENT_CLAIM_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-runtime/claims}"
# How many nested holds one claim tolerates before the recursion guard bites.
# Inheritance without a cap is a fork bomb: every descendant may re-farm the
# ticket it was spawned for.
AGENT_CLAIM_MAX_DEPTH="${AGENT_CLAIM_MAX_DEPTH:-3}"

_agent_claim_sanitize() {
  local value
  value="$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g; s/^-*//; s/-*$//' | cut -c1-96)"
  case "$value" in ''|.|..) return 1 ;; esac
  printf '%s\n' "$value"
}

_agent_claim_path() {
  local id
  id="$(_agent_claim_sanitize "$1")" || return 1
  printf '%s/%s\n' "$AGENT_CLAIM_DIR" "$id"
}

_agent_claim_field() {
  local path="$1" key="$2"
  [ -f "$path" ] || return 1
  awk -F= -v k="$key" '$1==k { print substr($0, index($0, "=")+1); exit }' "$path"
}

_agent_claim_pid_alive() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# Parent of a pid. /proc where it exists, ps elsewhere. comm can hold
# spaces and parens, so the fields are taken after the last ')'.
_agent_claim_ppid() {
  local pid="$1" stat
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    stat="${stat##*') '}"
    # shellcheck disable=SC2086
    set -- $stat
    printf '%s\n' "${2:-}"
    return 0
  fi
  stat="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' \n')"
  case "$stat" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$stat"
}

# Start at BASHPID so each worker subshell has a distinct identity.
_agent_claim_is_ancestor() {
  local target="$1" pid="${BASHPID:-$$}" hops=0
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$hops" -lt 64 ]; do
    [ "$pid" = "$target" ] && return 0
    pid="$(_agent_claim_ppid "$pid")" || return 1
    case "$pid" in ''|0|1) return 1 ;; esac
    hops=$((hops + 1))
  done
  return 1
}

# A detached terminal can reparent workers. Pass the claim ID and holder PID to children.
_agent_claim_owned_has() {
  local id="$1" pid="$2" e
  for e in ${AGENT_CLAIM_OWNED:-}; do
    [ "$e" = "$id:$pid" ] && return 0
  done
  return 1
}

_agent_claim_owned_count() {
  local id="$1" e n=0
  for e in ${AGENT_CLAIM_OWNED:-}; do
    case "$e" in "$id":*) n=$((n + 1)) ;; esac
  done
  printf '%s\n' "$n"
}

_agent_claim_own() {
  local id="$1" pid="$2"
  _agent_claim_owned_has "$id" "$pid" && return 0
  AGENT_CLAIM_OWNED="${AGENT_CLAIM_OWNED:+$AGENT_CLAIM_OWNED }$id:$pid"
  export AGENT_CLAIM_OWNED
}

# Depth of the hold this caller would be taking: the holder entry plus one
# id:nested:<pid> marker per level already taken in THIS branch of the process
# tree, so two sibling workers under one claim each start from depth 2 rather
# than pushing each other toward the guard. The file's nested= lines are the
# fallback for when the env was lost and only the /proc chain granted it — they
# count siblings too, which errs toward refusing.
_agent_claim_depth() {
  local id="$1" path="$AGENT_CLAIM_DIR/$1" env_n file_n
  env_n="$(_agent_claim_owned_count "$id")"
  if [ "$env_n" -gt 0 ]; then
    printf '%s\n' "$((env_n + 1))"
    return 0
  fi
  file_n="$(grep -c '^nested=' "$path" 2>/dev/null || true)"
  [ -n "$file_n" ] || file_n=0
  printf '%s\n' "$((file_n + 1))"
}

# Serialize stale-owner checks and publish complete records before another worker sees them.
_agent_claim_install() {
  python3 - "$1" "$2" <<'PY'
import errno
import fcntl
import os
from pathlib import Path
import sys
import tempfile

path = Path(sys.argv[1])
directory = os.open(path.parent, os.O_RDONLY)
try:
    fcntl.flock(directory, fcntl.LOCK_EX)
    try:
        fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    except FileNotFoundError:
        fields = None
    if fields is not None:
        try:
            pid = int(fields.get("pid", ""))
            if pid > 0:
                os.kill(pid, 0)
                sys.exit(1)
        except ValueError:
            pass
        except OSError as error:
            if error.errno == errno.EPERM:
                sys.exit(1)
            if error.errno != errno.ESRCH:
                raise
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".claim-", delete=False) as temp:
        try:
            temp.write(sys.argv[2] + "\n")
            temp.close()
            os.replace(temp.name, path)
        finally:
            if os.path.exists(temp.name):
                os.unlink(temp.name)
    if fields is not None:
        print(f"claim: took over stale {path.name} (dead pid {fields.get('pid') or 'none'})", file=sys.stderr)
except (OSError, OverflowError, UnicodeError) as error:
    print(f"claim: {error}", file=sys.stderr)
    sys.exit(2)
finally:
    os.close(directory)
PY
}

# Terminate a partial line before appending fields.
_agent_claim_append_line() {
  local path="$1" line="$2"
  [ -z "$(tail -c1 "$path" 2>/dev/null)" ] || printf '\n' >> "$path"
  printf '%s\n' "$line" >> "$path"
}

agent_claim_id_from() {
  local s ticket slug upcase_s
  for s in "$@"; do
    [ -n "$s" ] || continue
    # Fold ticket case in filenames only. Paths and prose can contain model names.
    if printf '%s\n' "$s" | grep -qE '[/[:space:]]'; then
      ticket="$(printf '%s\n' "$s" | grep -oE '(^|[^A-Za-z0-9_-])[A-Z]{2,10}-[0-9]+' | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)"
    else
      upcase_s="$(printf '%s\n' "$s" | tr '[:lower:]' '[:upper:]')"
      ticket="$(printf '%s\n' "$upcase_s" | grep -oE '(^|[^A-Z0-9_-])[A-Z]{2,10}-[0-9]+' | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)"
    fi
    if [ -n "$ticket" ]; then
      printf '%s\n' "$ticket"
      return 0
    fi
  done
  slug="$(_agent_claim_sanitize "${1:-}")" || return 1
  printf '%s\n' "$slug"
}

# $5 is the owning pid, passed in because this function's caller reads it from
# BASHPID: computing it here would capture the pid of the $( ) subshell, which
# is dead the instant the claim is written.
agent_claim_body() {
  local runtime="${2:-${AGENT_RUNTIME:-unknown}}"
  local worktree="${3:-}" branch="${4:-}" self="${5:-$$}"
  if [ -z "$worktree" ]; then
    worktree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  if [ -z "$branch" ]; then
    branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
  fi
  printf 'pid=%s\nruntime=%s\nstarted_at=%s\nworktree=%s\nbranch=%s\n' \
    "$self" "$runtime" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$worktree" "$branch"
}

agent_claim_summary() {
  local path pid
  path="$(_agent_claim_path "$1")" || return 1
  [ -f "$path" ] || return 1
  pid="$(_agent_claim_field "$path" pid)"
  printf 'pid=%s runtime=%s worktree=%s branch=%s started_at=%s' \
    "$pid" \
    "$(_agent_claim_field "$path" runtime)" \
    "$(_agent_claim_field "$path" worktree)" \
    "$(_agent_claim_field "$path" branch)" \
    "$(_agent_claim_field "$path" started_at)"
}

agent_claim_busy() {
  local path pid
  path="$(_agent_claim_path "$1")" || return 1
  [ -f "$path" ] || return 1
  pid="$(_agent_claim_field "$path" pid)"
  _agent_claim_pid_alive "$pid"
}

agent_claim_branch_busy() {
  local want="${1:-}" path pid br
  want="${want#refs/heads/}"
  want="${want#refs/remotes/origin/}"
  want="${want#origin/}"
  [ -n "$want" ] || return 1
  [ -d "$AGENT_CLAIM_DIR" ] || return 1
  for path in "$AGENT_CLAIM_DIR"/*; do
    [ -f "$path" ] || continue
    pid="$(_agent_claim_field "$path" pid)"
    _agent_claim_pid_alive "$pid" || continue
    br="$(_agent_claim_field "$path" branch)"
    br="${br#refs/heads/}"
    br="${br#refs/remotes/origin/}"
    br="${br#origin/}"
    if [ -n "$br" ]; then
      [ "$br" = "$want" ] && return 0
      continue
    fi
    if declare -F agent_claim_branch_policy >/dev/null &&
        agent_claim_branch_policy "${path##*/}" "$want"; then
      return 0
    fi
  done
  return 1
}

# The live holder is me, an ancestor of me, or a holder I inherited by env.
agent_claim_mine() {
  local id path pid
  id="$(_agent_claim_sanitize "${1:-}")" || return 1
  path="$AGENT_CLAIM_DIR/$id"
  [ -f "$path" ] || return 1
  pid="$(_agent_claim_field "$path" pid)"
  _agent_claim_pid_alive "$pid" || return 1
  _agent_claim_owned_has "$id" "$pid" && return 0
  _agent_claim_is_ancestor "$pid"
}

# free | foreign | depth. Only foreign is a real collision; depth is this
# lineage re-farming the same id past AGENT_CLAIM_MAX_DEPTH.
agent_claim_block_reason() {
  local id
  id="$(_agent_claim_sanitize "${1:-}")" || { echo free; return 0; }
  if ! agent_claim_busy "$id"; then echo free; return 0; fi
  if ! agent_claim_mine "$id"; then echo foreign; return 0; fi
  if [ "$(_agent_claim_depth "$id")" -gt "$AGENT_CLAIM_MAX_DEPTH" ]; then
    echo depth
    return 0
  fi
  echo free
}

agent_claim_blocked() {
  [ "$(agent_claim_block_reason "${1:-}")" != free ]
}

# Refusal text a worker cannot mistake for "someone else has this handled, so I
# am done". Callers print this and exit non-zero.
agent_claim_refusal() {
  local id="${1:-}" prefix="${2:-claim}" reason
  reason="$(agent_claim_block_reason "$id")"
  case "$reason" in
    foreign)
      printf '%s: REFUSED %s — already claimed by a DIFFERENT live session (%s).\n' \
        "$prefix" "$id" "$(agent_claim_summary "$id")"
      printf '%s: nothing ran for %s. This is not success, not a completion, and not evidence that the work is covered.\n' \
        "$prefix" "$id"
      printf '%s: correct response — wait for that session to finish, or pick different work. Do not stand down as done.\n' \
        "$prefix"
      ;;
    depth)
      printf '%s: REFUSED %s — recursion guard: my own lineage already claimed it %s deep (max %s); this is not a sibling session.\n' \
        "$prefix" "$id" "$(_agent_claim_depth "$id")" "$AGENT_CLAIM_MAX_DEPTH"
      printf '%s: nothing ran for %s. Do the remaining scope in this session instead of farming %s again.\n' \
        "$prefix" "$id" "$id"
      ;;
    *) return 1 ;;
  esac
}

agent_claim_acquire() {
  local raw="$1" id path body pid
  # Record the acquiring subshell so sibling workers have separate claims.
  local self="${BASHPID:-$$}"
  id="$(_agent_claim_sanitize "$raw")" || { echo "claim: bad id" >&2; return 2; }
  path="$AGENT_CLAIM_DIR/$id"
  mkdir -p "$AGENT_CLAIM_DIR"
  body="$(agent_claim_body "$id" "${2:-}" "${3:-}" "${4:-}" "$self")"

  local result=0
  _agent_claim_install "$path" "$body" || result=$?
  case "$result" in
    0) _agent_claim_own "$id" "$self"; return 0 ;;
    1) ;;
    *) return "$result" ;;
  esac
  pid="$(_agent_claim_field "$path" pid)"
  if _agent_claim_pid_alive "$pid"; then
    # My own lineage: a nested hold. The file is left alone so release by a
    # descendant cannot drop the ancestor's claim.
    if agent_claim_mine "$id" && [ "$(_agent_claim_depth "$id")" -le "$AGENT_CLAIM_MAX_DEPTH" ]; then
      _agent_claim_append_line "$path" "nested=$self"
      _agent_claim_own "$id" "$pid"
      _agent_claim_own "$id" "nested:$self"
      echo "claim: $id inherited from my own lineage (holder pid=$pid) — nested hold" >&2
      return 0
    fi
    agent_claim_refusal "$id" claim >&2
    return 1
  fi
  agent_claim_refusal "$id" claim >&2
  return 1
}

# Only the recording process drops the claim: a descendant holding it nested
# must leave the ancestor's claim standing.
agent_claim_release() {
  local path pid
  path="$(_agent_claim_path "${1:-}")" || return 0
  [ -f "$path" ] || return 0
  pid="$(_agent_claim_field "$path" pid)"
  if [ "$pid" = "${BASHPID:-$$}" ]; then
    rm -f "$path"
  fi
}

agent_claim_hold() {
  agent_claim_acquire "$@" || return $?
  # Chain with any existing EXIT handler so both owners can clean up.
  local existing_trap
  existing_trap="$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")"
  local release_cmd="agent_claim_release $(printf %q "$1")"
  # Chain: run release, then existing trap if any.
  # shellcheck disable=SC2064
  if [ -n "$existing_trap" ]; then
    trap "$release_cmd; $existing_trap" EXIT
  else
    trap "$release_cmd" EXIT
  fi
}

agent_claim_wrap() {
  local id="${1:-}" rt="${2:-unknown}"
  [ -n "$id" ] || { echo "claim: wrap needs an id" >&2; return 2; }
  shift 2
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { echo "claim: wrap needs a command" >&2; return 2; }
  agent_claim_hold "$id" "$rt" || return $?
  "$@"
}

_agent_claim_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_agent_claim_here/agent-claim-policy.sh" ]; then
  . "$_agent_claim_here/agent-claim-policy.sh"
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  case "${1:-}" in
    acquire) shift; agent_claim_acquire "$@" ;;
    release) shift; agent_claim_release "$@" ;;
    wrap) shift; agent_claim_wrap "$@" ;;
    busy)
      shift
      if agent_claim_busy "${1:-}"; then echo held; exit 0; fi
      echo free; exit 1
      ;;
    mine)
      shift
      if agent_claim_mine "${1:-}"; then echo mine; exit 0; fi
      echo "not-mine"; exit 1
      ;;
    blocked)
      shift
      if agent_claim_blocked "${1:-}"; then
        agent_claim_refusal "${1:-}" claim
        exit 0
      fi
      echo free; exit 1
      ;;
    reason) shift; agent_claim_block_reason "${1:-}" ;;
    show) shift; agent_claim_summary "${1:-}"; echo; [ -f "$(_agent_claim_path "${1:-}")" ] ;;
    id-from) shift; agent_claim_id_from "$@" ;;
    path) shift; _agent_claim_path "${1:-}" ;;
    branch-busy)
      shift
      if agent_claim_branch_busy "${1:-}"; then echo held; exit 0; fi
      echo free; exit 1
      ;;
    *)
      if declare -F agent_claim_policy_command >/dev/null; then
        agent_claim_policy_command "${1:-}" "${@:2}" && exit 0
        rc=$?
        [ "$rc" = 2 ] || exit "$rc"
      fi
      echo "usage: agent-claim.sh acquire|release|wrap <id> [rt] -- <cmd>|busy|mine|blocked|reason|show|id-from|path|branch-busy <id>" >&2
      exit 2
      ;;
  esac
fi
