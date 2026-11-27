---
name: layered-one-pass
description: Design a product, workflow, integration, or multi-part goal around the user's complete journey and intended result; find missing handoffs, choose a proportionate solution, and deliver dependent layers with evidence.
---

# Plan once, finish by layer

Use the existing plan, issue, or design note; do not create another planning
system. Scale depth to risk: a small change can be a short mental walkthrough
and one layer. For a substantial goal, make the following reasoning reviewable.

1. **Define the result.** State whose work improves, what they are trying to
   achieve, and the observable result beyond the requested artifact or feature.
   Read relevant product strategy and current behavior. Separate confirmed
   facts, assumptions, and questions that could change the solution. Resolve
   routine choices from evidence; ask only for a consequential missing decision.
2. **Trace the whole path.** Follow a realistic user from the preceding trigger
   through the requested step to the result and subsequent follow-up. Inspect
   the actual repos, screens, records, integrations, and deployment surfaces at
   each handoff. Identify who acts next, what context must travel with them, and
   where progress currently stops. Do not assume a named feature or connected
   account proves the next step works.
3. **Choose the smallest complete solution.** Compare reuse, a simpler/manual
   path, buying, building, or omitting a component when they are credible
   alternatives. Check access, operating cost, maintenance, and user effort,
   not just implementation effort. Recommend a choice. Prefer a direct edit at
   the owning source; preserve shared behavior unless a requirement or evidence
   demands divergence. Do not add configuration or abstractions for hypothetical
   variants. For substantial API/data-shape choices, sketch representative
   caller code first; name access patterns, ownership and tradeoffs before
   settling signatures. Preserve deliberate protocol and migration boundaries.
   Include dependencies required for the outcome; defer unnecessary
   adjacent improvements. Broader inspection does not expand authorization.
4. **Make handoffs explicit.** For each boundary the change touches, identify
   the source record and owner, actor/permission, triggering action, context
   carried forward, visible state and next action, and confirmation of success.
   Define approval, cancellation/correction, delay, failure, and retry behavior
   where applicable; prevent stale approvals or duplicate external effects.
   Reuse the system of record rather than creating parallel copies. Identify
   how the intended result will be observed, with the minimum useful evidence.
5. **Walk the experience before building.** From each affected role, describe
   the normal path and the relevant interruption or mistake. Can a new user
   understand where they are, what to do next, what happened, and how to recover
   without an explanation from the builder? Remove repeated entry, hidden
   transitions, dead ends, and unnecessary choices. Verify the interaction in
   the real rendered surface when available; do not invent more UI for every
   edge case.
6. **Deliver by dependency.** Group changes sharing a root cause. Assign
   independent substantial work using the [manager workflow](../manager/SKILL.md);
   give overlapping files one owner and name who owns the handoffs. Track real blocking dependencies in the existing issue tracker.
   Deliver the smallest usable slice through the complete path. Update the
   plan when evidence changes it; avoid deploying between tiny related edits.
7. **Verify the outcome.** Exercise the integrated path at real entry points,
   including relevant roles, a failure/recovery case, and the downstream result.
   Use authorized sandbox or controlled checks for external effects. Distinguish
   implemented, connected, verified, and blocked; passing component tests is
   not proof of a working journey. Report missing access or human decisions
   precisely and continue other authorized work. Finish when the original
   outcome is met, not when each worker has produced an artifact.

Show the concise plan and concrete scenarios when they help the user assess
scope. An empty ready set means inspect real blockers or stop; it is not a
reason to create more work.

If the project lacks reproducible verification instructions, use
[create-verification-skill](../create-verification-skill/SKILL.md) at the owning
project. For a named race, retry or state-machine invariant that ordinary tests
cannot cover adequately, use [verify-invariants](../verify-invariants/SKILL.md).
