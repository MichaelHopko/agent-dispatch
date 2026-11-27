# Manager

Manager launches interactive coding sessions and runs headless jobs from the command line. It selects among your installed Claude, Codex, Grok, and Cursor CLIs using their remaining quota.

## Install and run

On Linux or macOS, install Python 3.9+, Bash and Git. Install and sign in to at least one supported agent CLI on the computer that will run jobs.

```sh
git clone https://github.com/MichaelHopko/agent-dispatch.git
cd agent-dispatch
./install.sh
export PATH="$HOME/.local/bin:$PATH"

manager status
manager run "Summarize this workspace"
```

`manager "goal"` opens an interactive session in the terminal. `manager run` runs headlessly, accepts a goal as arguments or stdin, and returns the provider output and exit status. Use `manager -a grok` for an interactive Grok session, or `manager run --agent codex "Review the current branch"` for a headless job pinned to Codex. Keep the checkout in place because the installed commands link to it. Run Manager from the workspace you want the agent to use.

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

Use `manager plugin list` to see bundled and enabled plugins. For a basic review, set the workspace and enable daily learnings:

```sh
export MANAGER_LEARNINGS_WORKSPACE="$PWD"
manager plugin enable daily-learnings
manager watch
```

Run `manager watch` periodically with cron, launchd or a systemd user timer. Set the same configuration in the scheduler environment. `manager plugin disable NAME` removes the enabled link. Provider routing and interactive sessions work without scheduling any jobs.

| Optional capability | Setup |
| --- | --- |
| Coordinate workers, collect reports and answer questions | [Worker coordination](docs/workers.md) and [manager roles](docs/coordination.md) |
| Learn from local Claude, Codex, Cursor or Grok sessions | [Session discovery, debriefs and daily learnings](docs/learning.md) |
| File or update a Linear issue, run a worker, and verify delivery before closing it | [Linear intake and ticket workers](docs/linear.md) |
| Review pull requests, keep Git repositories current, or run recurring project briefs | [GitHub and scheduled integrations](docs/integrations.md) |
| Supervise services specific to an installation | [Service hooks](docs/services.md) |

To add your own plugin, link its directory under `~/.config/manager/plugins/`. An executable named `start`, `status`, `watch`, or `recover` runs during that lifecycle command. For scheduled work provide an `interval` file containing positive seconds and an executable `run`. Manager records successful completion and locks each scheduled plugin against overlapping runs. Supply project policies, data sources and credentials through local configuration.

## OpenClaw integration

If you already use OpenClaw, run `./install.sh --openclaw` on its gateway host to add the [Manager skill](skills/manager-cli/SKILL.md) to that profile. Open a new chat and ask it to use Manager for a task.
