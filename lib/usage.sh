#!/usr/bin/env bash
# Parse provider usage reports into remaining quota windows.
agent_runtime_parse_claude_usage() {
  CLAUDE_USAGE_TEXT="$1" python3 - <<'PY'
import json, os, re

text = os.environ.get("CLAUDE_USAGE_TEXT", "")
stripped = text.lstrip()
if stripped.startswith("{"):
    try:
        data = json.loads(text)
        if isinstance(data, dict) and isinstance(data.get("result"), str):
            text = data["result"]
    except json.JSONDecodeError:
        pass

parts = []
m = re.search(r"Current session:\s*(\d+)%\s*used", text)
if m:
    parts.append("session %d%% left" % (100 - int(m.group(1))))
m = re.search(r"Current week \(all models\):\s*(\d+)%\s*used", text)
if m:
    parts.append("week %d%% left" % (100 - int(m.group(1))))
else:
    m = re.search(r"Current week:\s*(\d+)%\s*used", text)
    if m:
        parts.append("week %d%% left" % (100 - int(m.group(1))))
m = re.search(r"Current week \(Sonnet only\):\s*(\d+)%\s*used", text)
if m:
    parts.append("sonnet-week %d%% left" % (100 - int(m.group(1))))
print(" · ".join(parts) if parts else "UNKNOWN")
PY
}

# Parse GET /backend-api/wham/usage JSON. Label windows by duration.
agent_runtime_parse_codex_wham() {
  CODEX_USAGE_JSON="$1" python3 - <<'PY'
import json, os

def window_label(secs, fallback):
    if secs is None:
        return fallback
    try:
        secs = int(secs)
    except (TypeError, ValueError):
        return fallback
    if secs >= 86400 * 6:
        return "week"
    if 3600 <= secs <= 6 * 3600:
        return "5h"
    return fallback

def used_left(window):
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
    if used is None:
        return None
    try:
        left = 100 - int(round(float(used)))
    except (TypeError, ValueError):
        return None
    return max(0, min(100, left))

try:
    data = json.loads(os.environ.get("CODEX_USAGE_JSON", "") or "")
except json.JSONDecodeError:
    print("UNKNOWN")
    raise SystemExit

rl = data.get("rate_limit") if isinstance(data, dict) else None
if not isinstance(rl, dict):
    print("UNKNOWN")
    raise SystemExit

parts = []
for key, fallback in (("primary_window", "primary"), ("secondary_window", "secondary")):
    window = rl.get(key)
    left = used_left(window)
    if left is None:
        continue
    label = window_label(window.get("limit_window_seconds"), fallback)
    parts.append("%s %d%% left" % (label, left))
print(" · ".join(parts) if parts else "UNKNOWN")
PY
}

# Parse POST GetCurrentPeriodUsage JSON. remaining/limit as a percent.
agent_runtime_parse_cursor_period() {
  CURSOR_USAGE_JSON="$1" python3 - <<'PY'
import json, os

try:
    data = json.loads(os.environ.get("CURSOR_USAGE_JSON", "") or "")
except json.JSONDecodeError:
    print("UNKNOWN")
    raise SystemExit

plan = data.get("planUsage") if isinstance(data, dict) else None
if not isinstance(plan, dict):
    print("UNKNOWN")
    raise SystemExit
remaining, limit = plan.get("remaining"), plan.get("limit")
try:
    remaining = float(remaining)
    limit = float(limit)
except (TypeError, ValueError):
    print("UNKNOWN")
    raise SystemExit
if limit <= 0:
    print("UNKNOWN")
    raise SystemExit
pct = int(round(100.0 * remaining / limit))
print("plan %d%% left" % max(0, min(100, pct)))
PY
}

# Parse GET /v1/billing?format=credits JSON. Remaining = 100 - used.
agent_runtime_parse_grok_billing() {
  GROK_USAGE_JSON="$1" python3 - <<'PY'
import json, os

try:
    data = json.loads(os.environ.get("GROK_USAGE_JSON", "") or "")
except json.JSONDecodeError:
    print("UNKNOWN")
    raise SystemExit

config = data.get("config") if isinstance(data, dict) else None
if not isinstance(config, dict):
    print("UNKNOWN")
    raise SystemExit

used = config.get("creditUsagePercent")
if used is None:
    on_used = config.get("onDemandUsed")
    on_cap = config.get("onDemandCap")
    if isinstance(on_used, dict):
        on_used = on_used.get("val")
    if isinstance(on_cap, dict):
        on_cap = on_cap.get("val")
    try:
        on_used = float(on_used)
        on_cap = float(on_cap)
    except (TypeError, ValueError):
        print("UNKNOWN")
        raise SystemExit
    if on_cap <= 0:
        print("UNKNOWN")
        raise SystemExit
    used = 100.0 * on_used / on_cap

try:
    left = 100 - int(round(float(used)))
except (TypeError, ValueError):
    print("UNKNOWN")
    raise SystemExit
left = max(0, min(100, left))

period = ""
cur = config.get("currentPeriod")
if isinstance(cur, dict):
    period = str(cur.get("type") or "")
if "WEEKLY" in period:
    label = "week"
elif "MONTHLY" in period:
    label = "month"
elif "DAILY" in period:
    label = "day"
else:
    label = "credits"
print("%s %d%% left" % (label, left))
PY
}

# True when any reported window is 0% left. UNKNOWN is not 0%.
agent_runtime_remaining_zero() {
  case "$1" in
    UNKNOWN|"") return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '(^|[[:space:]])0% left'
}

# Tightest "N% left" window as an integer, or UNKNOWN. Multiple windows
# (session + week) use the minimum.
agent_runtime_remaining_pct() {
  local rem="$1" min="" n
  case "$rem" in
    UNKNOWN|"") echo UNKNOWN; return ;;
  esac
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -z "$min" ] || [ "$n" -lt "$min" ]; then
      min="$n"
    fi
  done <<EOF
$(printf '%s' "$rem" | grep -oE '[0-9]+% left' | grep -oE '[0-9]+' || true)
EOF
  if [ -z "$min" ]; then
    echo UNKNOWN
  else
    echo "$min"
  fi
}


