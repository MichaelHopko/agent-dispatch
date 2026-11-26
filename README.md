# Quota Dispatcher

A standalone extraction of the quota routing policy from Michael Hopko's dotfiles runtime selector. It routes delegated jobs among locally configured subscriptions. Bash 4+ and standard Unix utilities are required. The optional provider usage parsers also use Python 3.

## Configure profiles

Put one profile name per line in `~/.config/quota-dispatcher/order`, in priority order. For each profile, create an executable `run` in its profile directory. The adapter receives the arguments and standard input passed to the dispatcher.

For example, with Codex CLI already authenticated locally:

```sh
config="${XDG_CONFIG_HOME:-$HOME/.config}/quota-dispatcher"
mkdir -p "$config/codex"
printf '%s\n' codex > "$config/order"
cat > "$config/codex/run" <<'ADAPTER'
#!/usr/bin/env bash
exec codex exec "$@"
ADAPTER
chmod +x "$config/codex/run"
```

Add additional profiles the same way. Each can wrap a different provider CLI or its own authenticated configuration. Use separate profile names for independently managed quotas.

An optional executable `usage` reports windows such as `session 30% left · week 80% left`, or `UNKNOWN` if the quota cannot be measured. An exhausted window makes the profile ineligible. Unknown quota remains eligible. `lib/usage.sh` includes the extracted parsers for Claude, Codex, Cursor, and Grok response formats. The dispatcher does not query provider endpoints or read credentials itself.

## Run jobs

```sh
./quota-dispatch status
./quota-dispatch pick
./quota-dispatch run 'Summarize this list and suggest next steps'
./quota-dispatch limit codex 1800
```

An adapter can return exit code 75 when it confirms provider quota exhaustion. The dispatcher records a cooldown and returns the failure to the caller. The next invocation selects the next eligible profile. This avoids replaying work that may already have taken effect. The minimal Codex adapter above passes through native exit codes. For automatic cooldowns, use an adapter that translates a confirmed quota error to 75.

`QUOTA_DISPATCH_CONFIG` and `QUOTA_DISPATCH_STATE` override the config and state directories. `QUOTA_DISPATCH_COOLDOWN` sets the default cooldown in seconds.

## OpenClaw and dotfiles

For delegated tasks, configure an OpenClaw tool or skill that can invoke the absolute path to `quota-dispatch run` under the account that owns the adapter configuration. The CLI is ready to call from a subprocess. Native OpenClaw integration and provider authentication are outside this extraction.

Dotfiles can pin a release of this repo and source `lib/usage.sh` to share the usage parsing and exhaustion rules. Keep the current launcher, job claims, and supervision in dotfiles. Migrate callers to the standalone CLI after verifying parity for their runtime profiles.
