"""Replay a delivery check inside a real Orca terminal and isolated Git worktree."""
import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=60).strip()


def orca(*args):
    payload = json.loads(run(os.environ.get("ORCA_BIN", "orca"), *args, "--json"))
    if not payload["ok"]:
        raise RuntimeError(payload["error"])
    return payload["result"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("workspace", type=Path, help="New directory for the replay repository")
    parser.add_argument("--agent", help="Additionally launch a real authenticated agent in the review worktree")
    args = parser.parse_args()
    repo = args.workspace.resolve()
    repo.mkdir(parents=True, exist_ok=False)
    run("git", "init", "-qb", "main", cwd=repo)
    (repo / "verify.py").write_text(Path(__file__).with_name("verify.py").read_text())
    run("git", "add", "verify.py", cwd=repo)
    run("git", "-c", "user.name=Replay", "-c", "user.email=replay@example.invalid",
        "commit", "-qm", "Add delivery contract fixtures", cwd=repo)
    orca("repo", "add", "--path", str(repo))
    orca("worktree", "create", "--repo", "path:" + str(repo), "--name", "delivery-review",
         "--base-branch", "main", "--setup", "skip")
    worktrees = run("git", "worktree", "list", "--porcelain", cwd=repo)
    review, = [Path(s[9:]) for s in worktrees.splitlines()
               if s.startswith("worktree ") and Path(s[9:]).resolve() != repo]
    selector = "path:" + str(review)
    orca("terminal", "create", "--worktree", selector, "--title", "Delivery checks",
         "--command", shlex.join(["python3", "verify.py"]))
    receipt = review / "receipt.json"
    for _ in range(120):
        if receipt.exists():
            break
        time.sleep(0.5)
    result = json.loads(receipt.read_text())
    assert result == {"accepted_orders": 1, "deployment": "pending", "publication": "pending"}
    assert not (repo / "receipt.json").exists()
    print(json.dumps({"worktree": str(review), "verified": result}))
    if args.agent:
        print(json.dumps(orca("agent", "launch", "--worktree", selector, "--agent", args.agent,
                              "--prompt", "Review verify.py and receipt.json. Explain exactly which claims are supported.")))


if __name__ == "__main__":
    main()
