import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

cache = os.environ.get("SESSION_DEBRIEF_CACHE") or os.path.expanduser("~/.cache/session-debrief")
queue = os.environ.get("QUEUE") or os.path.join(cache, "queue.jsonl")
log_path = os.environ.get("LOG") or os.path.join(cache, "run.log")
LEARNING_KEYS = frozenset({"learning", "why", "where"})
DEFERRED_KEYS = frozenset({"transcript", "status"})


def log_line(msg):
    os.makedirs(cache, exist_ok=True)
    with open(log_path, "a") as fh:
        fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + msg + "\n")


def preview(line):
    s = line.replace("\n", "\\n")
    return s if len(s) <= 160 else s[:157] + "..."


def is_learning(line):
    raw = line.strip()
    if not raw:
        return False
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return False
    if not isinstance(obj, dict) or set(obj.keys()) != LEARNING_KEYS:
        return False
    if not all(isinstance(obj[k], str) and obj[k].strip() for k in LEARNING_KEYS):
        return False
    return True


def is_deferred(obj):
    return (
        isinstance(obj, dict)
        and set(obj.keys()) == DEFERRED_KEYS
        and obj.get("status") == "deferred"
        and isinstance(obj.get("transcript"), str)
        and obj["transcript"].strip()
    )


def with_lock(fn):
    os.makedirs(cache, exist_ok=True)
    lock_path = os.path.join(cache, "queue.lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fn()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def append_bytes(payload):
    if not payload:
        return
    os.makedirs(os.path.dirname(queue) or ".", exist_ok=True)
    with open(queue, "ab") as fh:
        fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())


def cmd_append():
    accepted = []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        if not is_learning(line):
            log_line("reject queue line: %s" % preview(line))
            continue
        policy = os.environ.get("SESSION_DEBRIEF_POLICY")
        if policy:
            reason = subprocess.run([policy], input=line, text=True,
                                    capture_output=True, check=True).stdout.strip()
            if reason:
                log_line("reject %s: %s" % (reason, preview(line)))
                continue
        accepted.append(line.strip() + "\n")
    append_bytes("".join(accepted).encode())


def cmd_append_deferred():
    transcript = sys.argv[2] if len(sys.argv) > 2 else ""
    obj = {"transcript": transcript, "status": "deferred"}
    if not is_deferred(obj):
        log_line("reject deferred: %s" % preview(transcript))
        return
    append_bytes((json.dumps(obj, separators=(",", ":")) + "\n").encode())


def cmd_delete_processed():
    try:
        n = int(sys.argv[2])
    except (IndexError, ValueError):
        sys.exit(2)
    if n < 0:
        sys.exit(2)
    if n == 0 or not os.path.isfile(queue):
        return
    with open(queue, "rb") as fh:
        data = fh.read()
    replace_queue(b"".join(data.splitlines(keepends=True)[n:]))


def acknowledge():
    snapshot = Path(sys.argv[2]).read_bytes()
    if not snapshot or snapshot == b"(empty)\n" or not Path(queue).exists():
        return
    if not snapshot.endswith(b"\n"):
        sys.exit("expected complete queue records")
    data = Path(queue).read_bytes()
    if data.startswith(snapshot):
        replace_queue(data[len(snapshot):])


def show_queue():
    sys.stdout.buffer.write(Path(queue).read_bytes() if Path(queue).exists() else b"(empty)\n")


def replace_queue(kept):
    tmp = queue + ".tmp.%d" % os.getpid()
    with open(tmp, "wb") as fh:
        fh.write(kept)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, queue)


def mark_seen():
    transcript = sys.argv[2]
    seen = os.path.join(cache, "debriefed.txt")
    with open(seen, "a+") as fh:
        fh.seek(0)
        if any(line.rstrip("\n") == transcript for line in fh):
            return False
        fh.write(transcript + "\n")
        return True


cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "claim":
    sys.exit(0 if with_lock(mark_seen) else 1)
elif cmd == "queue":
    with_lock(show_queue)
elif cmd == "acknowledge" and len(sys.argv) == 3:
    with_lock(acknowledge)
elif cmd == "append":
    with_lock(cmd_append)
elif cmd == "append-deferred":
    with_lock(cmd_append_deferred)
elif cmd == "delete-processed":
    with_lock(cmd_delete_processed)
else:
    sys.exit(2)
