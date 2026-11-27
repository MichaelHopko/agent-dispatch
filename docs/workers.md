# Worker coordination

Use these Bash helpers from a Manager checkout when a launcher needs to reserve a task, accept a worker's question, or collect progress and completion evidence. The helpers use Bash, Python 3 and a state directory shared with the coordinator. Claims coordinate processes on one host.

## Reserve a task

Wrap the worker so that the process holding the claim stays alive until the worker exits. The command returns the worker's exit code. A second, unrelated holder of the same ID is refused before its command runs.

```sh
workers="$PWD/lib/workers"
"$workers/agent-claim.sh" wrap OPS-12 codex -- manager run --agent codex "Review the proposed schedule"
"$workers/agent-claim.sh" show OPS-12
```

A shell launcher can instead source `agent-claim.sh` and call `agent_claim_hold OPS-12 codex`. The claim records the holder PID, recovers from a dead holder on the next acquisition and chains the caller's EXIT trap. Set `AGENT_CLAIM_DIR` to share a different claim directory. All participating processes must see the same PIDs.

## Ask and answer

Give each worker a task name that is a single filename component. A task name and directory identify one question and its answer. Use a fresh name or directory for a new question.

```sh
export AGENT_ASK_DIR="$PWD/run/questions" AGENT_ASK_TASK=OPS-12
"$workers/agent-ask.sh" ask "Should weekends be included?" --default "Keep weekday hours"
```

From another process, list outstanding questions and reply to the appropriate worker.

```sh
"$workers/agent-ask.sh" pending "$PWD/run/questions"
"$workers/agent-ask.sh" answer "$PWD/run/questions" OPS-12 "Include Saturday morning"
```

The worker receives the literal answer on stdout. A call waits up to `AGENT_ASK_WAIT_SECS` (90 seconds by default). After a wait expires, run `"$workers/agent-ask.sh" wait` with the same environment. Once the original question reaches `AGENT_ASK_DEADLINE_SECS` (600 seconds by default), the command prints the proposed default action for the worker to carry out.

## Report progress and completion

Supply the worker's measured exit status, Git state and write count. A task file can declare expected artifacts with one `EXPECT: <glob>` line per artifact. Paths are relative to the working directory passed to `send`.

```sh
mkdir -p run
printf 'EXPECT: schedule.md\n' > run/task
export AGENT_REPORT_TO_SESSION=weekend-planning
"$workers/agent-report.sh" progress run/OPS-12.progress "Reviewed the weekday schedule"
"$workers/agent-report.sh" send --task OPS-12 --runtime codex \
  --rc "$worker_rc" --git "$git_state" --writes "$write_count" --taskfile run/task --cwd "$PWD"
"$workers/agent-report.sh" inbox weekend-planning
"$workers/last-success-epoch.sh" verdict run/OPS-12.cache 600
```

The inbox contains JSON Lines. Check both the completion `verdict` and the artifact `evidence`. For example, a successful worker that changed files can return `OK` while its expected output is missing. For tasks that deliver an external result, a task-file line containing `Deliverable: off-repo` accepts exit zero without local changes. The coordinator still needs to verify the external result.

Progress updates refresh a timestamp in the task's cache. The final command above reports `alive`, `stale` or `never` for a 600-second freshness interval. It measures the age of the latest progress update.

The default claims and reports directories live under `${XDG_STATE_HOME:-$HOME/.local/state}/agent-runtime`. Set `AGENT_REPORT_DIR` to change the inbox location. A launcher can capture the originating Claude Code session with `agent-report.sh origin` and pass that trusted file to `send --dispatcher FILE` for best-effort socket delivery. Without a session name, the default inbox is `nodispatcher.jsonl`. Set `AGENT_REPORT_NOTIFY_CMD` to an executable notification hook for undelivered reports. It receives the event name as its first argument and JSON on stdin.
