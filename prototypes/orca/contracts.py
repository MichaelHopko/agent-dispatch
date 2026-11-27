"""Inspect the installed Orca executable and run the synthetic delivery fixture offline."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from replay import binary


COMMANDS = {
    "worktree create": ["repo", "base-branch", "agent", "setup"],
    "terminal create": ["worktree", "command"],
    "terminal read": ["terminal", "cursor"],
    "agent launch": ["worktree", "agent", "prompt"],
    "agent read": [],
    "orchestration worker-start": ["task", "spec-file", "worktree", "agent", "model"],
    "orchestration gate-create": [],
    "linear search": [], "linear create": [], "linear comment add": [], "linear status set": [],
    "automations create": [],
    "search": [],
}

def main():
    cli = binary()
    registry = json.loads(subprocess.check_output([cli, "agent-context", "--json"], text=True))
    cmds = {row["command"]: set(row["flags"]) for row in registry["commands"]}
    for name, flags in COMMANDS.items():
        if name not in cmds or set(flags) - cmds[name]:
            raise RuntimeError(f"Missing CLI command or flags: {name} {flags}")
    skills = json.loads(subprocess.check_output([cli, "skills", "list", "--json"], text=True))
    for name in ("orca-linear", "orca-cli", "orchestration"):
        if name not in {topic["name"] for topic in skills["topics"]}:
            raise RuntimeError(f"Missing bundled skill: {name}")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run([sys.executable, str(Path(__file__).with_name("verify.py").resolve())], cwd=tmp, check=True)
        fixture = json.loads((Path(tmp) / "receipt.json").read_text())
        if fixture != {"accepted_orders": 1, "deployment": "pending", "publication": "pending"}:
            raise RuntimeError(f"Unexpected fixture receipt: {fixture}")
    print(json.dumps({"installed_cli_contracts": sorted(COMMANDS), "fixture": fixture}))

if __name__ == "__main__":
    main()
