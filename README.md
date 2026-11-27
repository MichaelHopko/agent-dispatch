# Dispatcher

Route delegated jobs across AI subscriptions from one command. Set a priority order and the dispatcher picks the first profile with a runnable adapter, no active cooldown, and no reported exhausted quota window.

## Quick start

You’ll need Bash 4 or later and an authenticated provider CLI. This example uses Codex.

```sh
git clone https://github.com/MichaelHopko/agent-dispatch.git
cd agent-dispatch

config="${QUOTA_DISPATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/quota-dispatcher}"
mkdir -p "$config/codex"
test -f "$config/order" || printf '%s\n' codex > "$config/order"

cat > "$config/codex/run" <<'ADAPTER'
#!/usr/bin/env bash
exec codex exec "$@"
ADAPTER
chmod +x "$config/codex/run"

./dispatch status
./dispatch run 'Summarize the files in this directory'
```

To add a subscription, create an executable `run` in its own profile directory and list the profile in `order`. List one profile per line, highest priority first. The adapter receives the arguments and standard input passed to `run`.

## Quota and cooldowns

A profile can provide an executable `usage` that prints remaining quota, for example `session 30% left · week 80% left`. A window at 0% makes the profile ineligible. A missing meter, a failed meter, or `UNKNOWN` leaves the profile eligible. Optional parsers for Claude, Codex, Cursor, and Grok are in `lib/usage.sh` and require Python 3.

An adapter can return exit code 75 to signal a confirmed provider limit. The dispatcher records a cooldown and returns 75 to the caller. The next job can use another profile. The Codex example passes through the CLI’s exit code. To signal limits automatically, use an adapter that returns 75 for confirmed provider limits.

| Command | Behavior |
| --- | --- |
| `./dispatch status` | Show profiles, eligibility, and reported quota. |
| `./dispatch pick` | Print the first eligible profile. |
| `./dispatch run [args...]` | Run the job through the first eligible profile. |
| `./dispatch limit PROFILE [SECONDS]` | Put a profile on cooldown. |

Set `QUOTA_DISPATCH_CONFIG` or `QUOTA_DISPATCH_STATE` to override the directories. By default, they’re under `$XDG_CONFIG_HOME` and `$XDG_STATE_HOME`, with fallbacks to `~/.config` and `~/.local/state`. Set `QUOTA_DISPATCH_COOLDOWN` to change the default cooldown from 3,600 seconds.

## Calling from OpenClaw

From a tool that can launch a local subprocess, call `/absolute/path/to/dispatch run` with the job’s arguments. Run it under the account that owns the configured provider profiles, and surface the command’s exit status to the caller.
