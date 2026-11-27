---
name: create-verification-skill
description: "Create or maintain project-owned verification instructions that launch, check, drive and clean up a real app with durable evidence and a feature entry-point map. Use when future agents lack a reproducible way to verify user behavior."
---

# Make the next agent able to verify the app

Read the owning repository's instructions and existing verification skill
first. Improve that skill when present. Use the repository's canonical skills
directory and registration rules. Keep verification recipes alongside the product.

## Discover the existing path

Inspect the real entry points, run commands, dependencies, auth, storage,
migrations, seed data and existing browser/CLI/API harness. Identify which
resources can be isolated. Reuse the harness; do not create another driver
merely because it is unfamiliar. Missing access or a broken base is a reported
blocker, not authority for unrelated fixes or tool installations.

## Write executable instructions

Make the instructions usable by an agent that has never seen the project:

- **Launch.** Exact existing commands, isolated ports/profiles/data, required
  environment names, and the signal that a usable app is ready. A process
  answering a health request does not prove migrations or login completed.
- **Doctor.** Read-only confirmation of expected build/version, instance and
  port ownership, auth and required services. Check it before driving an
  unfamiliar existing instance; never take over the user's session.
- **Drive.** Real selectors, commands or requests from the repository. Prefer
  semantic handles and verify transitions, not fixed sleeps. Exercise real
  entry points rather than internal setters or test-only shortcuts.
- **Evidence.** Record the action and independently expected resulting state.
  Check side effects as well as the visible result. Record commit, commands,
  fixture/real-data boundary and artifact location. Never publish credentials
  or private records. A dry run's name does not prove it has no effects.
- **Cleanup.** Remove only resources this run created; stop owned process IDs,
  never broad process-name matches. Keep evidence outside disposable state,
  and verify it survives cleanup. Clean up failed attempts too.

## Map the behavior

In the existing verification location, keep a small feature index with paths
for the most important journeys. Each states the user's intent, every relevant
entry point, preconditions, driving commands, observable result and known
limits. Reuse existing specs rather than duplicating their implementation.
A toolbar flow passing does not prove the equivalent keyboard or CLI path.
Missing fixture preconditions are coverage gaps, not grounds to weaken checks.

## Prove and maintain it

Run the written instructions from launch through doctor, one mapped journey,
evidence capture and cleanup. Confirm the artifacts survive and the observed
result matches expectations. Exercise other mapped paths when the change needs
them; mark unexercised paths explicitly. An unrun recipe is a draft.

When behavior changes, update its mapped path and rerun affected instructions.
If verification uses a stand-in, name setup it supplied that the real target
does not and retain those target checks as unverified. Do not schedule upkeep,
perform customer sends or change production to test the instructions.
