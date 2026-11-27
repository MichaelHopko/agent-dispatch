# Linear intake and ticket execution

Enable daily learnings to review workspace sessions. Connect its findings to Linear by exporting the following settings in the environment that runs Manager. Obtain the team key from a Linear issue identifier (for example, `ENG` in `ENG-24`).

```sh
export MANAGER_LEARNINGS_WORKSPACE=/absolute/path/to/your/repo
export MANAGER_CLI="$(command -v manager)"
export MANAGER_LINEAR_TEAM=ENG
export MANAGER_LEARNINGS_INTAKE=/absolute/path/to/agent-dispatch/plugins/linear/linear.py
# Supply LINEAR_API_KEY from your secret store.
```

The review reads this workspace's debrief queue and recent sessions, checks evidence, and updates guidance where appropriate. Set `MANAGER_LEARNINGS_EVIDENCE` to point the review at another evidence directory. The review gets the candidate queue as a snapshot. A failed review keeps the entries. A completed review acknowledges that prefix after intake succeeds. Completed edits and observations that need no action can yield zero findings.

Linear intake searches existing issues in the selected team, including closed and archived items. When there are plausible matches, Manager evaluates whether they describe the same work. New evidence goes on the matching issue. A new finding creates one issue with its evidence and done criteria. Stable finding keys, a team-and-workspace ledger, and persisted mutation identifiers protect retries. The default new-issue cap is three per UTC day. Set `MANAGER_LINEAR_DAILY_CAP` to override it. On an unavailable service or a cap, the next sweep resumes its pending findings.

## Run ticket workers

```sh
export MANAGER_TICKET_QUEUE="$MANAGER_LEARNINGS_INTAKE"
export MANAGER_TICKET_WORKSPACE="$MANAGER_LEARNINGS_WORKSPACE"
export MANAGER_TICKET_VERIFY=/absolute/path/to/your-verifier
```

Enable the `daily-learnings` and `ticket-worker` plugins and run `manager watch` periodically. Each installation handles the Linear issues it creates in its workspace-scoped state directory. When using separate checkouts of the same project, set the same explicit `MANAGER_LINEAR_SCOPE` on the learning and worker processes. Use one worker host for each team and workspace. New unassigned work should be placed in the team's backlog or unstarted state. The worker takes a local claim, rereads the current issue, runs the job, and invokes your verifier with the job directory. Supply a verifier that reads the issue ID, goal and result, checks the actual delivery condition, and prints its evidence receipt. For example, for a code delivery verify the requested regression test and the landed commit. Verifier failure keeps the ticket open.

Manager posts the verifier receipt to the issue before transitioning it to a completed state. If multiple completed states exist, set `MANAGER_LINEAR_DONE_STATE` to its exact name. The next worker pass resumes a verified delivery after a Linear outage.

Use `linear.py list` for local claim status. After checking an interrupted or failed job for partial work and confirming the previous worker has stopped, `linear.py retry ENG-24` returns the claim to the queue. Linear matches from other sources receive evidence and retain their existing ownership.
