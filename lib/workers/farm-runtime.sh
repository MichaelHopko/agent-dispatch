#!/usr/bin/env bash
_farm_mem_available_kb() {
  local n path="${FARM_MEMINFO:-/proc/meminfo}"
  [ -r "$path" ] || return 1
  n="$(awk '/^MemAvailable:/ { print $2; exit }' "$path" 2>/dev/null)" || n=""
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$n"
}

# Unavailable memory readings leave the caller's worker-count limit in effect.
_farm_mem_refuse_avail() {
  local avail min="${FARM_MEM_AVAILABLE_MIN_KB:-2097152}"
  case "$min" in
    ''|*[!0-9]*) min=2097152 ;;
  esac
  avail="$(_farm_mem_available_kb)" || return 1
  [ "$avail" -lt "$min" ] || return 1
  printf '%s\n' "$avail"
}

_farm_is_wsl() {
  case "${FARM_IS_WSL:-}" in 0) return 1 ;; 1) return 0 ;; esac
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null
}

_farm_wsl_host_snapshot() {
  local ps distro="${WSL_DISTRO_NAME:-}" script snapshot
  if [ "${FARM_WSL_POWERSHELL+x}" = x ]; then
    ps="$FARM_WSL_POWERSHELL"
  else
    ps="$(command -v powershell.exe 2>/dev/null)" || ps=""
    # User-systemd services do not inherit Windows PATH entries.
    if [ -z "$ps" ]; then
      for ps in /mnt/*/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
        [ -x "$ps" ] && break
      done
    fi
  fi
  [ -n "$ps" ] && [ -x "$ps" ] || return 127
  if [ -z "$distro" ]; then
    distro="$(wslpath -w / 2>/dev/null | awk -F'\\' '{print $4}')"
  fi
  [ -n "$distro" ] || return 2
  script="\$distro='${distro//\'/\'\'}';"$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$d = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\*' | Where-Object { $_.DistributionName -eq $distro })
if ($d.Count -ne 1) { exit 2 }
$base = [Environment]::ExpandEnvironmentVariables($d[0].BasePath)
$vhd = $d[0].VhdFileName
if ([string]::IsNullOrWhiteSpace($vhd)) { $vhd = 'ext4.vhdx' }
$volume = @(Get-Volume -FilePath (Join-Path $base $vhd))
$memory = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
if ($volume.Count -ne 1 -or $null -eq $volume[0].SizeRemaining -or $null -eq $memory) { exit 2 }
'{0} {1}' -f [long]$memory, [long][math]::Floor($volume[0].SizeRemaining / 1KB)
PS
)
  snapshot="$(timeout 8 "$ps" -NoProfile -NonInteractive -Command "$script" 2>/dev/null)" || return $?
  printf '%s\n' "$snapshot" | tr -d '\r'
}

_farm_resource_refuse() {
  local avail snapshot disk min per reserve rc
  _farm_resource_problem=""
  _farm_host_mem_kb=""
  if avail="$(_farm_mem_refuse_avail)"; then
    _farm_resource_problem="memory pressure MemAvailable=${avail}kB — not spawning"
    return 0
  fi
  _farm_is_wsl || return 1
  snapshot="$(_farm_wsl_host_snapshot)"; rc=$?
  if [ "$rc" -ne 0 ] || ! [[ "$snapshot" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    _farm_resource_problem="WSL host resources unverified (query exit $rc) — not spawning"
    return 0
  fi
  _farm_host_mem_kb="${BASH_REMATCH[1]}"
  disk="${BASH_REMATCH[2]}"
  min="${FARM_MEM_AVAILABLE_MIN_KB:-2097152}"
  case "$min" in ''|*[!0-9]*) min=2097152 ;; esac
  per="${FARM_MEM_PER_WORKER_KB:-$min}"
  case "$per" in ''|*[!0-9]*) per="$min" ;; esac
  [ "$per" -gt 0 ] || per="$min"
  reserve=5242880  # Preventive 5GiB reserve for the VHD's Windows volume.
  if [ "$_farm_host_mem_kb" -lt "$((min + per))" ]; then
    _farm_resource_problem="WSL host memory pressure available=${_farm_host_mem_kb}kB required=$((min + per))kB — not spawning"
  elif [ "$disk" -lt "$reserve" ]; then
    _farm_resource_problem="WSL backing-volume disk pressure free=${disk}kB reserve=${reserve}kB — not spawning"
  else
    return 1
  fi
}

# Reserve a memory floor and cap new workers by the remaining headroom.
_farm_mem_parallel_cap() {
  local avail min per slots host_slots maxp="${FARM_MAX_PARALLEL:-6}"
  case "$maxp" in
    ''|*[!0-9]*) maxp=6 ;;
  esac
  [ "$maxp" -gt 0 ] || maxp=6
  min="${FARM_MEM_AVAILABLE_MIN_KB:-2097152}"
  case "$min" in
    ''|*[!0-9]*) min=2097152 ;;
  esac
  per="${FARM_MEM_PER_WORKER_KB:-$min}"
  case "$per" in
    ''|*[!0-9]*) per="$min" ;;
  esac
  [ "$per" -gt 0 ] || per="$min"
  if avail="$(_farm_mem_available_kb)"; then
    if [ "$avail" -lt "$min" ]; then
      printf '0\n'
      return 0
    fi
    slots=$(( (avail - min) / per ))
    [ "$slots" -ge 1 ] || slots=1
  else
    slots="$maxp"
  fi
  if [ -n "${_farm_host_mem_kb:-}" ]; then
    host_slots=$(( (_farm_host_mem_kb - min) / per ))
    [ "$host_slots" -ge 0 ] || host_slots=0
    [ "$slots" -le "$host_slots" ] || slots="$host_slots"
  fi
  [ "$slots" -le "$maxp" ] || slots="$maxp"
  printf '%s\n' "$slots"
}

# The caller owns this process group. Only signal its members.
_farm_reap_pgid() {
  local pgid="$1" pid
  [ -n "$pgid" ] || return 0
  case "$pgid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pgid" -gt 1 ] || return 0
  for pid in $(ps -axo pid=,pgid= | awk -v g="$pgid" '$2 == g { print $1 }'); do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] || continue
    [ "$pid" != "$$" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.05
  for pid in $(ps -axo pid=,pgid= | awk -v g="$pgid" '$2 == g { print $1 }'); do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt 1 ] || continue
    [ "$pid" != "$$" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
}

# Called from a worker wrapper's signal trap with its child process group.
_farm_wrapper_signaled() {
  local pid="${1:-}" out="${2:-}" grace=0 st
  trap - TERM INT HUP
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    while [ "$grace" -lt 25 ]; do
      st="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
      case "$st" in ''|Z*) break ;; esac
      sleep 0.2
      grace=$((grace + 1))
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    _farm_reap_pgid "$pid"
    [ -z "$out" ] || printf 'farm: wrapper signaled — worker group killed\n' >> "$out" 2>/dev/null || true
  fi
  exit 143
}

# Count records naming a file-mutating tool.
_farm_count_write_tools() {
  local f="$1" n
  [ -f "$f" ] || { echo 0; return; }
  n="$(grep -cE '"(toolName|name|title)"[[:space:]]*:[[:space:]]*"(write|Write|search_replace|StrReplace|Edit|MultiEdit|NotebookEdit|apply_patch|Delete|delete)"' "$f" || true)"
  echo "${n:-0}"
}

# Claude can write journal entries while stdout remains buffered.
_farm_claude_transcript_mtime() {
  local slug dir m
  slug="$(printf '%s' "${1:-}" | sed 's![^A-Za-z0-9]!-!g')"
  dir="$HOME/.claude/projects/$slug"
  [ -d "$dir" ] || { echo 0; return 0; }
  m="$(find "$dir" -maxdepth 1 -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d. -f1)"
  printf '%s\n' "${m:-0}"
}

# Output, process-group CPU, journals, and explicit heartbeats signal liveness.
_farm_progress_token() {
  local pgid="$1" out="$2" bytes cpu tmt hb
  bytes="$(wc -c < "$out" 2>/dev/null || echo 0)"
  cpu="$(ps -axo pgid=,times= 2>/dev/null \
    | awk -v g="$pgid" '$1 == g { s += $2 } END { print s + 0 }')"
  tmt="$(_farm_claude_transcript_mtime "$PWD")"
  hb="$(stat -c %Y "${out%.out}.hb" 2>/dev/null || echo 0)"
  printf '%s:%s:%s:%s\n' "${bytes:-0}" "${cpu:-0}" "${tmt:-0}" "${hb:-0}"
}

# A marker older than the task start belongs to a previous attempt.
_farm_fresh_marker() {
  local f="$1" startf="$2"
  [ -f "$f" ] || return 1
  if [ -f "$startf" ] && [ "$f" -ot "$startf" ]; then
    return 1
  fi
  return 0
}
