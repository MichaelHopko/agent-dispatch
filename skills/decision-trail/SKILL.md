---
name: decision-trail
description: "Keep a compact evidence-linked decision trail for substantial unattended runs, optimization attempts or long delegated work; audit what changed and why without treating a log as proof of delivery."
---

# Leave a reviewable decision trail

Use the existing task's evidence location, not another backlog or status
database. Skip a separate log for routine small changes. For a substantial
run, choose one log per owner and record its path in the existing batch/task
state so a replacement can find it. Do not have concurrent writers share one
log. Keep customer data, secrets and private transcripts out of its fields.

Append a row as a consequential decision happens:

```bash
bash <skill-dir>/scripts/log.sh <log.tsv> <phase> <decision> <why> <evidence> <result>
```

The helper creates a TSV header and normalizes tabs/newlines and formula-like
cells. It does not execute evidence, verify claims or deliver work. Evidence
should point to the tested commit, command/result, artifact or external receipt.
Record rejected attempts and blockers as well as accepted changes. The skill
directory is the one this SKILL.md was loaded from; do not assume a home path.

For review, reconcile rows against current diffs, tests and actual delivery.
Read raw evidence for material claims. A stale row, successful process exit or
worker summary is not proof. Preserve evidence through cleanup; follow repository
policy for committing or privately retaining the trail. Do not publish a log or
schedule a reviewer merely because this skill exists.
