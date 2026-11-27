_review_extract_body() {
  local stdout="$1" last="${2:-}" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/pr-review-extract.XXXXXX")"
  printf '%s' "$stdout" > "$tmp"
  python3 - "$tmp" "${last:-}" <<'PY'
import json, sys
from pathlib import Path

def strip_transport(text):
    drop_substrings = (
        "Reading additional input from stdin",
        "Connection lost, reconnecting",
        "Retry attempt",
        "OpenAI Codex v",
    )
    drop_exact = {"--------", "user"}
    drop_prefixes = (
        "workdir:",
        "model:",
        "provider:",
        "approval:",
        "sandbox:",
        "reasoning effort:",
        "reasoning summaries:",
        "session id:",
    )
    out = []
    for line in text.splitlines():
        if any(s in line for s in drop_substrings):
            continue
        stripped = line.strip()
        if stripped in drop_exact:
            continue
        low = stripped.lower()
        if any(low.startswith(p) for p in drop_prefixes):
            continue
        out.append(line)
    return "\n".join(out).strip()

def from_jsonl(text):
    last = ""
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith("{"):
            continue
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        item = obj.get("item")
        if isinstance(item, dict) and item.get("type") == "agent_message":
            t = item.get("text") or item.get("message")
            if isinstance(t, str) and t.strip():
                last = t
        payload = obj.get("payload")
        if isinstance(payload, dict):
            lam = payload.get("last_agent_message")
            if isinstance(lam, str) and lam.strip():
                last = lam
            elif (
                payload.get("type") == "agent_message"
                and payload.get("phase") == "final_answer"
            ):
                msg = payload.get("message")
                if isinstance(msg, str) and msg.strip():
                    last = msg
        if obj.get("type") == "result" and isinstance(obj.get("result"), str):
            if obj["result"].strip():
                last = obj["result"]
    return last.strip()

stdout = Path(sys.argv[1]).read_text()
last_path = sys.argv[2] if len(sys.argv) > 2 else ""
last = ""
if last_path:
    p = Path(last_path)
    if p.is_file():
        last = p.read_text()
body = last.strip() or from_jsonl(stdout) or stdout
sys.stdout.write(strip_transport(body))
PY
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

_review_body_unpostable() {
  local body="$1"
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 0
  printf '%s' "$body" | grep -qE \
    'Reading additional input from stdin|OpenAI Codex v|Connection lost, reconnecting|--- DIFF ---|--- END DIFF ---|Review this pull request diff|^[[:space:]]*\{[[:space:]]*"type":[[:space:]]*"(thread\.started|item\.|turn\.)' \
    && return 0
  return 1
}
