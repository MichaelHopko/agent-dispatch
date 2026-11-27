# Orca delivery replay

Use a disposable checkout to exercise worktree creation, terminal output and an optional agent assessment on a running Orca host. An isolated quote-acceptance fixture receives the same event twice and checks the order count. A merged candidate with an older deployment revision and a draft without a publication receipt both remain pending.

```sh
python3 prototypes/orca/contracts.py
python3 prototypes/orca/replay.py /tmp/new-replay-project --agent codex
```

Set `ORCA_BIN` to the executable if it is outside PATH. The live replay requires the CLI and runtime on the same machine with access to the chosen project directory. The agent option also needs a signed-in provider. The review worktree stays open for inspecting the diff and terminal in the editor. Use a different fresh project path for another run.

The offline command queries the installed Orca command registry and skills and runs the synthetic fixture directly. The live command creates an Orca worktree and a real terminal on the running server, checks the receipt in that checkout, and verifies that the source checkout has no receipt. With `--agent` it requires a machine-readable assessment from the chosen agent.

## Verification

Orca's 1.4.278 Linux server release supplied all thirteen CLI contracts, including session search, Linear issue operations, automation, supervised workers, terminal history, and agent launch. The offline fixture returned one order and two pending external outcomes. The local environment denied the runtime's Unix socket listener at startup. Interactive UI, worker supervision, connector writes and agent assessment remain unverified in this environment.

Manager's portable pieces can also run under another launcher. Trial-specific checks belong in the task brief and delivery verifier. This example uses local synthetic data and creates no real orders, deployments, publications, or Linear issues.
