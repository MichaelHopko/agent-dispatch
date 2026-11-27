#!/usr/bin/env bash
set -eu
source "$(dirname "$0")/../lib/workers/farm-runtime.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export FARM_MEMINFO="$tmp/meminfo" FARM_IS_WSL=0
export FARM_MEM_AVAILABLE_MIN_KB=4000 FARM_MEM_PER_WORKER_KB=1000 FARM_MAX_PARALLEL=6
printf 'MemAvailable: 7000 kB\n' > "$FARM_MEMINFO"
if _farm_resource_refuse; then exit 1; fi
test "$(_farm_mem_parallel_cap)" = 3
printf 'MemAvailable: 3500 kB\n' > "$FARM_MEMINFO"
_farm_resource_refuse
test "$(_farm_mem_parallel_cap)" = 0
printf '{"name":"Write"}\n{"name":"Read"}\n' > "$tmp/task.out"
test "$(_farm_count_write_tools "$tmp/task.out")" = 1
touch -t 202001010000 "$tmp/task.timeout"
touch -t 202001010001 "$tmp/task.start"
if _farm_fresh_marker "$tmp/task.timeout" "$tmp/task.start"; then exit 1; fi
touch "$tmp/task.timeout"
_farm_fresh_marker "$tmp/task.timeout" "$tmp/task.start"
before="$(_farm_progress_token 0 "$tmp/task.out")"
echo completed >> "$tmp/task.out"
test "$before" != "$(_farm_progress_token 0 "$tmp/task.out")"
