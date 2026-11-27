#!/usr/bin/env bash
# Time of the last successful unit of work for a job.

last_success_path() {
  printf '%s/last-success-epoch' "${1:-}"
}

# Per-task farm cache: <stem>.cache next to <stem>.wt / <stem>.progress.
last_success_farm_cache() {
  local p="${1:-}"
  case "$p" in
    *.wt) printf '%s.cache' "${p%.wt}" ;;
    *.progress) printf '%s.cache' "${p%.progress}" ;;
    *.cache) printf '%s' "$p" ;;
    *) printf '%s' "$p" ;;
  esac
}

last_success_write() {
  local cache="${1:-}" now
  [ -n "$cache" ] || return 1
  mkdir -p "$cache" || return 1
  now="$(date +%s)"
  printf '%s\n' "$now" > "$cache/last-success-epoch"
}

last_success_read() {
  local cache="${1:-}" v
  [ -f "$cache/last-success-epoch" ] || return 1
  v="$(tr -d '[:space:]' < "$cache/last-success-epoch")"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

last_success_age() {
  local cache="${1:-}" last now
  last="$(last_success_read "$cache")" || return 1
  now="$(date +%s)"
  printf '%s' "$((now - last))"
}

# last_success_verdict CACHE INTERVAL [GRACE] → alive|stale|never
last_success_verdict() {
  local cache="${1:-}" interval="${2:-0}" grace="${3:-0}" age
  case "$interval" in ''|*[!0-9]*) interval=0 ;; esac
  case "$grace" in ''|*[!0-9]*) grace=0 ;; esac
  age="$(last_success_age "$cache")" || { printf 'never'; return 0; }
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -lt $((interval + grace)) ]; then
    printf 'alive'
  else
    printf 'stale'
  fi
}

last_success_alive() {
  [ "$(last_success_verdict "${1:-}" "${2:-0}" "${3:-0}")" = alive ]
}

# last_success_print CACHE INTERVAL [LABEL]
last_success_print() {
  local cache="${1:-}" interval="${2:-0}" label="${3:-last-success}" age verdict
  verdict="$(last_success_verdict "$cache" "$interval")"
  age="$(last_success_age "$cache" 2>/dev/null || true)"
  case "$verdict" in
    never) printf '%s: never\n' "$label" ;;
    alive) printf '%s: alive (age %ss)\n' "$label" "${age:-0}" ;;
    stale) printf '%s: stale (age %ss)\n' "$label" "${age:-0}" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    path) last_success_path "$@" ;;
    farm-cache) last_success_farm_cache "$@" ;;
    write) last_success_write "$@" ;;
    read) last_success_read "$@" || exit 1 ;;
    age) last_success_age "$@" || exit 1 ;;
    verdict) last_success_verdict "$@" ;;
    alive) last_success_alive "$@" ;;
    print) last_success_print "$@" ;;
    *)
      echo "usage: last-success-epoch.sh write|read|age|verdict|alive|print|path|farm-cache CACHE ..." >&2
      exit 2
      ;;
  esac
fi
