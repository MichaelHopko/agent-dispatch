#!/usr/bin/env bash
set -eu
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$root" "$@" <<'PY'
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import shlex
import sys
import tempfile


def write_atomic(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            out.write(data)
            out.close()
            tmp.replace(path)
        finally:
            if tmp.exists():
                tmp.unlink()


def install():
    root = Path(sys.argv[1])
    parser = argparse.ArgumentParser(prog="./install.sh", description="Link the Manager CLI from this checkout.")
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local", help="install commands under PREFIX/bin")
    parser.add_argument("--openclaw", action="store_true", help="install the caller skill for the local OpenClaw profile")
    parser.add_argument("--openclaw-skills-dir", type=Path, help="install the caller skill under this directory")
    args = parser.parse_args(sys.argv[2:])
    bindir = args.prefix.expanduser().resolve() / "bin"
    links = {bindir / name: root / name for name in ("manager", "dispatch")}

    bindir.mkdir(parents=True, exist_ok=True)
    # A directory lock leaves the prefix free of installer state files.
    lock = os.open(bindir, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for dst, src in links.items():
            if not os.access(src, os.X_OK):
                parser.exit(1, f"Missing executable: {src}\n")
            if os.path.lexists(dst) and not (dst.is_symlink() and dst.resolve() == src.resolve()):
                parser.exit(1, f"Existing command at {dst}; choose a different --prefix.\n")

        if args.openclaw or args.openclaw_skills_dir:
            state_dir = Path(os.getenv("OPENCLAW_STATE_DIR", Path.home() / ".openclaw"))
            skills = args.openclaw_skills_dir or state_dir / "skills"
            directory = skills.expanduser().resolve() / "manager-cli"
            doc = directory / "SKILL.md"
            stamp = directory / ".manager-cli.sha256"
            if directory.is_symlink() or doc.is_symlink() or stamp.is_symlink():
                parser.exit(1, f"Existing linked skill at {directory}; select another skills directory.\n")
            source = (root / "skills/manager-cli/SKILL.md").read_text()
            rendered = source.replace("Executable: `manager`", f"Executable: `{shlex.quote(str(bindir / 'manager'))}`").encode()
            digest = hashlib.sha256(rendered).hexdigest()
            if doc.exists():
                old_digest = hashlib.sha256(doc.read_bytes()).hexdigest()
                if old_digest != digest and (not stamp.is_file() or stamp.read_text().strip() != old_digest):
                    parser.exit(1, f"Preserving an existing or edited skill at {doc}.\n")
            directory.mkdir(parents=True, exist_ok=True)
            write_atomic(doc, rendered)
            write_atomic(stamp, (digest + "\n").encode())
            print(f"OpenClaw skill: {doc}")

        for dst, src in links.items():
            if not dst.is_symlink():
                dst.symlink_to(src)
        print(f"Manager: {bindir / 'manager'}")
        if str(bindir) not in os.get_exec_path():
            print(f"Add the commands to this shell: export PATH={shlex.quote(str(bindir))}:\"$PATH\"")
    finally:
        os.close(lock)


try:
    install()
except OSError as exc:
    sys.exit(str(exc))
PY
