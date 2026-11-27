---
name: manager-cli
description: Delegate a bounded task to a local subscription-backed agent with Manager and return its result to the current conversation.
---

Executable: `manager`

Use the executable above on the host with the configured provider CLIs. Run it in the intended workspace. Delegate one goal per invocation and include the context, constraints, and completion check. Use a subprocess argument array when the tool supports one. A multiline brief can be passed on standard input.

| Arguments | Use |
| --- | --- |
| `run "goal"` | Delegate with automatic agent selection. |
| `run --agent grok "goal"` | Select Grok when the user requests it. Substitute another configured agent as needed. |
| `status` | Inspect available profiles and reported quota. |

Read stdout and the exit status. Return the relevant result to the originating conversation. For a requested external action, verify its receipt before reporting delivery. On failure, inspect stderr and any partial work before retrying. Exit 75 indicates a provider cooldown.
