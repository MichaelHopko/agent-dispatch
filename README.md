# Manager

Launch an interactive coding agent or delegate a job from OpenClaw, a shell, or a scheduled task. Manager uses installed Claude, Codex, Grok, and Cursor CLIs. Sign in through the provider CLI before its first run.

## Install and run

Requires Python 3.8+ on Linux or macOS, Bash, and at least one provider CLI on PATH.

```sh
git clone https://github.com/MichaelHopko/agent-dispatch.git
cd agent-dispatch
export PATH="$PWD:$PATH"

manager -a grok
manager --agent codex "Review the current branch"
manager run "Summarize today's changes"
manager status
```

`manager "goal"` opens an interactive session in the terminal. `manager run` runs headlessly, accepts a goal as arguments or stdin, and returns the provider output and exit status. Use `--agent` or `-a` to pin an eligible agent. For OpenClaw, install the [manager-cli skill](skills/manager-cli/SKILL.md) in its skills directory and make the Manager executable available on the gateway host. The working directory and provider logins belong to the user running the command.

## Routing

Manager checks provider usage windows before launch. A window at zero or an active cooldown excludes an agent. Unknown usage remains eligible. When possible Manager reserves agents below 15% and rotates among eligible agents with measured quota. If every reading is unknown it follows configured order. Provider usage formats and endpoints can vary with CLI version. Provider permission settings govern tool execution.

`manager pick` prints the next headless selection. `manager limit codex 1800` cools Codex down for 30 minutes. A headless adapter can return 75 for a quota limit. Manager also recognizes common limit messages at the end of a failed built-in CLI's stderr. The caller receives the failure and the next job can use another agent.

Place profile names one per line in `~/.config/manager/order` to set priority. A custom profile has executable `run` (headless) and/or `chat` (interactive) adapters in its profile directory. Adapters receive goal arguments and inherit stdin. An optional executable `usage` prints windows such as `week 63% left`. Use `MANAGER_BRIEF` for custom interactive and headless instructions for built-in agents. `QUOTA_DISPATCH_CONFIG`, `QUOTA_DISPATCH_STATE`, and `QUOTA_DISPATCH_COOLDOWN` override the profile directory, state directory, and default cooldown seconds.

## Startup and lifecycle hooks

`manager start` runs startup hooks in filename order. From a terminal it then opens a manager session. An unattended invocation exits after startup. An executable in `~/.config/manager/hooks/start.d/` is enough:

```sh
mkdir -p ~/.config/manager/hooks/start.d
cat > ~/.config/manager/hooks/start.d/10-workspace <<'SH'
#!/bin/sh
mkdir -p "$HOME/work/agent-jobs"
SH
chmod +x ~/.config/manager/hooks/start.d/10-workspace
```

Hooks inherit the environment, working directory, and absolute `MANAGER_CLI` path. Write startup hooks so they can safely run again. Long-lived services should start under a service supervisor and return. Use `status.d` for local status checks, `watch.d` for periodic checks, and `recover.d` for explicit recovery. A hook failure returns a nonzero status. Set `MANAGER_CONFIG` to change the configuration root.

## Plugins

Enable a plugin by linking its directory into `~/.config/manager/plugins/`. An executable named `start`, `status`, `watch`, or `recover` runs with that lifecycle command. For a scheduled job, add a positive interval in seconds in `interval` and an executable `run`. Invoke `manager watch` periodically with cron, launchd, or a systemd user timer. Each pass runs due jobs, records successful completion, and locks each scheduled job against overlapping invocations. Export plugin settings in the scheduler's environment.

| Plugin | Setup |
| --- | --- |
| [daily-learnings](plugins/daily-learnings) | Set `MANAGER_LEARNINGS_WORKSPACE` to the workspace whose guidance can improve, and `MANAGER_LEARNINGS_EVIDENCE` to session transcripts or notes. Reviews recent evidence daily. |
| [ticket-worker](plugins/ticket-worker) | Set `MANAGER_TICKET_WORKSPACE` and `MANAGER_TICKET_QUEUE`. The queue adapter receives `claim DIRECTORY` and atomically leases one eligible ticket, writing its ID to `id` and brief to `goal`. An empty directory means idle. On `complete DIRECTORY` or `failed DIRECTORY`, reconcile the lease using `id`, stdout in `result`, and stderr in `error`. The adapter owns lease expiry, retry policy, and verification before closing a ticket. |

```sh
mkdir -p ~/.config/manager/plugins
ln -s "$PWD/plugins/daily-learnings" ~/.config/manager/plugins/daily-learnings
```

Keep organization-specific sources and destinations in plugins. A PR reviewer consumes a diff and emits findings. A PR watcher reacts to changes. An intake plugin creates tickets, while a ticket worker claims existing ones. Scheduled research, digests, direction reviews, and dashboards can each supply their own inputs and delivery hooks.
