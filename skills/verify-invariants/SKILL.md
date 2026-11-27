---
name: verify-invariants
description: "Verify a named concurrency, retry, parser or state-machine property with model checking, a code verifier or generated inputs; maintain code/model correspondence and prove the check detects a broken variant."
---

# Verify a consequential invariant

Start from the named code and property in the request. State the property and
the user harm of violating it in plain language. Prefer ordinary behavior tests
when they answer the question; use formal methods where ordering, input space
or bounds justify them. This workflow does not authorize product fixes,
dependency installation, production access or repo-wide verification work.

1. Inspect actual functions, callers and state transitions at a pinned commit.
   Select the smallest tool already supported by the project that can answer
   the question: a model checker for event order, a code verifier for supported
   source, or generated-input testing for actual code when no suitable verifier
   exists. Name unavailable tooling instead of claiming verification.
2. Map every modeled state and action to concrete symbols. An atomic model
   step must correspond to atomic code: an await, transaction boundary or
   independent writer can invalidate that assumption. Include relevant retry,
   crash, cancellation and duplicate-effect boundaries.
3. State bounds and assumptions: actors, retries, input sizes, scheduling,
   storage guarantees and omitted external systems. A pass proves the stated
   model/bounds, not the whole product. Generated-input testing is testing,
   not an exhaustive proof.
4. Show the check can fail on a plausible isolated mutation of the guarded
   behavior, such as removing a guard or splitting a state update. Do not
   mutate shared/production code. Discard the owned mutation and rerun the
   unmodified case. Keep genuine current failures with their counterexamples;
   never weaken a property to manufacture a pass.
5. Leave a project-owned reproducible check and concise verification recipe.
   Name the tool version, command, covered symbols, bounds, evidence and the
   commit at which correspondence was checked. Use the repository's existing
   verification skill. A newly created one must be exercised end to end.
6. On maintenance, inspect changes since that commit and reconcile model with
   code before trusting the old result. Distinguish model drift, intended
   behavior changes and real invariant failures. Advance the correspondence
   commit only after checking the mapping and rerunning affected checks.

Report the property, tool, result, counterexample if any, bounds, exact rerun
command and limitations. Use plain steps or a compact diagram to explain a
failure; no specific diagram tool is required.
