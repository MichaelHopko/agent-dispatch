# Manager roles and verification

The [manager role](../skills/manager/SKILL.md) is embedded in the prompt Manager sends to its built-in agents. It defines responsibility for outcomes, worker ownership, recovery, integration, and delivery evidence. A runtime with skill discovery can load the same role from `skills/manager/`. The [manager-cli skill](../skills/manager-cli/SKILL.md) teaches the calling assistant how to invoke the executable.

For a workflow that crosses tools, teams, or services, use [layered-one-pass](../skills/layered-one-pass/SKILL.md) to identify who owns each handoff, what survives a retry, and how someone can verify the downstream result. The [decision trail](../skills/decision-trail/SKILL.md) records the evidence behind consequential choices in long or unattended work.

Use [verify-invariants](../skills/verify-invariants/SKILL.md) to exercise a specific property under retries, concurrency, or malformed input. Use [create-verification-skill](../skills/create-verification-skill/SKILL.md) to document a repeatable real-entry-point check for the owning project. Domain rules such as who approves a release belong in that project's instructions.
