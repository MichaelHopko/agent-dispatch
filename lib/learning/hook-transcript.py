import glob, json, os, sys
from pathlib import Path

cache = os.environ.get("SESSION_DEBRIEF_CACHE") or os.path.expanduser("~/.cache/session-debrief")
home = Path(os.environ.get("HOME") or Path.home())
log_path = os.path.join(cache, "run.log")

def log_line(msg):
    os.makedirs(cache, exist_ok=True)
    with open(log_path, "a") as fh:
        fh.write(msg + "\n")

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

PATH_KEYS = (
    "transcript_path", "transcriptPath", "agent_transcript_path",
    "agentTranscriptPath", "conversation_file", "conversationPath",
    "session_file", "sessionFile", "transcript", "chat_file", "chatFile",
)
SID_KEYS = ("session_id", "sessionId", "thread_id", "threadId")

def walk_paths(obj, acc):
    if isinstance(obj, dict):
        for key, val in obj.items():
            if key in PATH_KEYS and isinstance(val, str) and val.strip():
                acc.append(val.strip())
            else:
                walk_paths(val, acc)
    elif isinstance(obj, list):
        for item in obj:
            walk_paths(item, acc)

def first_sid(obj):
    if isinstance(obj, dict):
        for key in SID_KEYS:
            val = obj.get(key)
            if isinstance(val, str) and val.strip():
                return val.strip()
        for val in obj.values():
            found = first_sid(val)
            if found:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = first_sid(item)
            if found:
                return found
    return None

paths = []
walk_paths(data, paths)
for path in paths:
    print(path)
    sys.exit(0)

sid = first_sid(data)
if sid and isinstance(sid, str) and sid not in (".", "..") and "/" not in sid:
    sid = glob.escape(sid)
    patterns = (
        str(home / ".claude" / "projects" / "**" / (sid + ".jsonl")),
        str(home / ".codex" / "sessions" / "**" / ("*" + sid + "*.jsonl")),
        str(home / ".grok" / "sessions" / "**" / sid / "updates.jsonl"),
        str(home / ".grok" / "sessions" / "**" / sid / "chat_history.jsonl"),
        str(home / ".cursor" / "projects" / "**" / "agent-transcripts" / sid / (sid + ".jsonl")),
    )
    hits = []
    for pattern in patterns:
        hits.extend(glob.glob(pattern, recursive=True))
    hits = [h for h in hits if os.path.isfile(h)]
    if hits:
        hits.sort(key=os.path.getmtime, reverse=True)
        print(hits[0])
        sys.exit(0)

# No usable path. Log key names only — a hook payload can carry prompt text.
log_line("unrecognized hook payload keys: %s" % sorted(data.keys()))
