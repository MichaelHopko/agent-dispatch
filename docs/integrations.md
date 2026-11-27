# Optional integrations

Link a plugin directory under `~/.config/manager/plugins/` to enable it for `manager watch`. Set its environment in the process that runs the watch command.

| Plugin | Inputs | Result |
| --- | --- | --- |
| `repo-freshness` | `MANAGER_REPOS` points to a directory of Git checkouts with an `origin` remote | Every six hours, fetch remote refs and fast-forward the remote's default branch when Git permits. Active feature branches keep their checked-out state. |
| `github-review` | GitHub CLI with read access and `MANAGER_REVIEW_REPOS` containing space-separated `owner/repo` names | Every 15 minutes, review open PR diffs at their recorded head SHAs. The local Markdown result lives under `$XDG_STATE_HOME/manager/github-review/OWNER/REPO/NUMBER/SHA.md`. The remote PR stays under its existing review and merge policy. |
| `scheduled-briefs` | `MANAGER_BRIEFS_CATALOG` points to a JSON file containing job names, intervals, prompt files and workspaces | Every five minutes, run at most one due job. Each job's latest successful output lives in `$XDG_STATE_HOME/manager/scheduled-briefs/NAME/result.md`. Failures retain the prior result and the job stays due. |

The state directory defaults to `~/.local/state`. Supply one stable name per scheduled brief. Paths in a catalog resolve relative to that file. An optional executable `gate` runs in the job workspace, with exit code 0 for ready, 1 for skip, and other codes for failure.

```json
[
  {
    "name": "weekly-research",
    "every_seconds": 604800,
    "workspace": "notes",
    "brief": "briefs/research.md"
  }
]
```

For a digest, provide approved sources and the reporting window in a brief. A direction review can have its own schedule, evidence and decision owner. Keep project priorities, research catalogs, recipients, dashboard metrics, and send/merge rules in the consuming workspace. A Slack or OpenClaw gateway can call `manager run` and deliver its stdout in the originating conversation. PR-change remediation, authenticated incident intake, external publication, and production dashboards depend on each installation's event sources and authorization.
