#!/usr/bin/env bash
# Usage: fleet_ensure_services DIRECTORY NAME...
# Each service receives ensure-daemon. An optional fleet_clean_env function
# prints environment arguments, one per line, for detached startup.
fleet_ensure_services() {
  local dir="$1" line name script timer failures=0
  shift
  local -a clean=() deadline=()
  if declare -F fleet_clean_env >/dev/null; then
    while IFS= read -r line; do clean+=("$line"); done < <(fleet_clean_env)
  fi
  for timer in timeout gtimeout; do
    if command -v "$timer" >/dev/null 2>&1; then
      deadline=("$timer" --foreground --kill-after=5s 10s)
      break
    fi
  done
  for name in "$@"; do
    script="$dir/$name.sh"
    if [[ -x "$script" ]]; then
      "${deadline[@]}" env "${clean[@]}" "$script" ensure-daemon </dev/null || failures=1
    else
      printf 'manager: missing %s\n' "$script" >&2
      failures=1
    fi
  done
  return "$failures"
}

watch() {
  local procs name problems="" prev msg
  local down="" after
  procs="$(_daemon_procs)"
  for name in $SERVICES; do
    case "$procs" in *"/$name.sh daemon"*) ;; *) down="$down $name" ;; esac
  done
  problems="$(stop_orphans | sed 's/^manager: //; s/$/; /' | tr -d '\n')"
  ensure_all >/dev/null 2>&1
  after="$(_daemon_procs)"
  for name in $down; do
    case "$after" in
      *"/$name.sh daemon"*) problems="${problems}$name was down (restarted); " ;;
      *) problems="${problems}$name is down and did not start; " ;;
    esac
  done
  if declare -F fleet_extra_health >/dev/null; then
    problems="$problems$(fleet_extra_health)"
  fi
  mkdir -p "$WATCH_DIR"
  prev="$(cat "$WATCH_DIR/watch.last" 2>/dev/null)"
  printf '%s' "$problems" > "$WATCH_DIR/watch.last"
  echo "$(date -u +%FT%TZ) ${problems:-ok}" >> "$WATCH_DIR/watch.log"
  [ "$problems" = "$prev" ] && return 0
  if [ -n "$problems" ]; then
    msg="fleet watchdog: ${problems%; }"
  else
    msg="fleet watchdog: all clear"
  fi
  echo "$msg"
  "$CHANNEL" post "$msg" >/dev/null 2>&1 || echo "manager: channel post failed" >&2
}

install_watchdog() {
  local sc="${MANAGER_SYSTEMCTL:-systemctl}" lc="${MANAGER_LOGINCTL:-loginctl}"
  command -v "$sc" >/dev/null 2>&1 || return 0
  timeout 5 "$sc" --user show-environment >/dev/null 2>&1 || return 0
  if command -v "$lc" >/dev/null 2>&1; then
    timeout 5 "$lc" enable-linger "$(id -un)" || return
  fi
  mkdir -p "$UNIT_DIR"
  # ensure_all's detached daemons must outlive this oneshot.
  printf '%s\n' "[Unit]" "Description=fleet watchdog (manager watch)" "" \
    "[Service]" "Type=oneshot" "KillMode=process" \
    "TimeoutStartSec=4min" "TimeoutStopSec=5s" \
    "ExecStart=/bin/bash -lc '$FLEET_ENTRY watch'" \
    > "$UNIT_DIR/fleet-watchdog.service"
  printf '%s\n' "[Unit]" "Description=manager watch every 5 minutes" "" \
    "[Timer]" "OnBootSec=1min" "OnUnitActiveSec=5min" "" \
    "[Install]" "WantedBy=timers.target" \
    > "$UNIT_DIR/fleet-watchdog.timer"
  timeout 5 "$sc" --user daemon-reload \
    && timeout 5 "$sc" --user enable --now fleet-watchdog.timer >/dev/null 2>&1 \
    && echo "watchdog: every 5 min (systemctl --user list-timers fleet-watchdog.timer)"
}
