#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export MANAGER_CONFIG="$tmp/config" QUOTA_DISPATCH_CONFIG="$tmp/profiles" QUOTA_DISPATCH_STATE="$tmp/state"
export XDG_STATE_HOME="$tmp/xdg" PATH="$tmp/bin:$PATH"
export AGENT_RUNTIME_REMAINING_STUB_codex='session 0% left' AGENT_RUNTIME_REMAINING_STUB_grok='week 80% left'
mkdir -p "$tmp/bin" "$QUOTA_DISPATCH_CONFIG" "$MANAGER_CONFIG/hooks/start.d"
printf 'codex\ngrok\n' > "$QUOTA_DISPATCH_CONFIG/order"
cat > "$tmp/bin/grok" <<'AGENT'
#!/bin/sh
printf '%s\n' "$@"
AGENT
cp "$tmp/bin/grok" "$tmp/bin/codex"
chmod +x "$tmp/bin/"*
test "$(./manager pick)" = grok
./manager -a grok 'interactive goal' | grep -qx 'interactive goal'
./manager run --agent grok 'headless goal' | grep -qx 'headless goal'
printf 'stdin goal' | ./manager run | grep -qx 'stdin goal'
if ./manager run --agent codex blocked; then exit 1; fi
./manager limit grok 10
if ./manager pick; then exit 1; fi
export START_LOG="$tmp/start.log"
for n in 20 10; do
  printf '#!/bin/sh\necho %s >> "$START_LOG"\n' "$n" > "$MANAGER_CONFIG/hooks/start.d/$n"
  chmod +x "$MANAGER_CONFIG/hooks/start.d/$n"
done
./manager start </dev/null
test "$(cat "$START_LOG")" = "$(printf '10\n20')"
mkdir -p "$MANAGER_CONFIG/plugins/task"
printf '300\n' > "$MANAGER_CONFIG/plugins/task/interval"
cp "$MANAGER_CONFIG/hooks/start.d/10" "$MANAGER_CONFIG/plugins/task/run"
./manager watch
./manager watch
test "$(wc -l < "$START_LOG")" -eq 3
rm "$QUOTA_DISPATCH_STATE/grok.cooldown"
export MANAGER_LEARNINGS_WORKSPACE="$tmp" MANAGER_LEARNINGS_EVIDENCE="$tmp"
export MANAGER_CLI="$root/manager"
plugins/daily-learnings/run | grep -q 'Review session evidence'
export MANAGER_TICKET_WORKSPACE="$tmp" MANAGER_TICKET_QUEUE="$tmp/queue"
cat > "$MANAGER_TICKET_QUEUE" <<'QUEUE'
#!/bin/sh
case "$1" in
  claim) echo ticket1 > "$2/id"; echo 'Ticket goal' > "$2/goal" ;;
  complete) grep -qx 'Ticket goal' "$2/result" ;;
  *) exit 1 ;;
esac
QUEUE
chmod +x "$MANAGER_TICKET_QUEUE"
plugins/ticket-worker/run
