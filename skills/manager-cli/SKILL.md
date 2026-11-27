---
name: manager-cli
description: Delegate a bounded task to an installed agent CLI through Manager. Use when the user asks to delegate work or requests a particular subscription-backed agent.
---

Run `manager run "goal"` in the intended working directory. Include the outcome, relevant context, constraints, and how to verify success. Pass arguments as a subprocess argument array when available. For a long brief, send it on stdin to `manager run`. Use `--agent NAME` after `run` when the caller specifies an agent. Otherwise let Manager choose.

Return the result to the originating conversation. A nonzero exit means the caller should inspect the failure and any partial work before retrying. Exit 75 records a provider cooldown. Use `manager status` to inspect availability. Interactive sessions and startup hooks are separate operator commands.
