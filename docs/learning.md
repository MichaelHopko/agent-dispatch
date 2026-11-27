# Learn from agent sessions

Manager's reader understands local Claude Code, Codex, Grok, and Cursor transcripts. From the Manager checkout, identify recent sessions in a workspace:

```sh
lib/learning/session-transcripts.py list --workspace /path/to/project --since-hours 26
lib/learning/session-transcripts.py extract /path/to/session.jsonl
```

Use `search` to find a conversation by terms, `live` to show recent sessions, and `usage PATH --turn-id ID` to summarize native Codex token counts. `--help` lists the options for each command.

## Queue a session

To extract learning candidates immediately, run the debrief from the project checkout:

```sh
/path/to/manager/lib/learning/session-debrief.sh run /path/to/session.jsonl
/path/to/manager/lib/learning/session-debrief.sh queue
```

A provider SessionEnd hook can invoke the absolute path to `session-debrief.sh hook` with its JSON payload on stdin. An explicit transcript path or a locally resolvable session ID identifies the input. The hook launches one background review per transcript and suppresses recursive debriefs. It skips sessions shorter than 40 lines by default. Set `SESSION_DEBRIEF_MIN_LINES` to change this threshold.

Each queued learning contains `learning`, `why`, and `where`. When extraction fails the queue retains a deferred transcript pointer. The scheduler can retry or review it directly. Each review uses an available provider through Manager, with its normal quota and tool settings.

By default the queue belongs to the Git root or current directory. Set `SESSION_DEBRIEF_WORKSPACE` to select a different project, or `SESSION_DEBRIEF_CACHE` to share a particular queue between a hook and a reviewer. Run a single consumer per queue. Save `queue` output to a snapshot file, verify and resolve the candidates, then run `acknowledge SNAPSHOT_FILE` to remove the matching prefix. Later appends survive that operation. A failed delivery should leave its entries available for retry.

A site can set `SESSION_DEBRIEF_POLICY` to an executable that reads one validated learning object on stdin. Exit successfully with empty output to accept it, or print the reason to drop it. The [daily-learnings skill](../skills/daily-learnings/SKILL.md) describes evidence selection and delivery.
