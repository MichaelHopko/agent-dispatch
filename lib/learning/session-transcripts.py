#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import os
import re
from pathlib import Path


AGENTS = ("all", "claude", "codex", "grok", "cursor")
TEXT_TYPES = {"text", "input_text", "output_text"}
GROK_SKIP_TYPES = {"system", "reasoning", "tool_result", "backend_tool_call"}
SKIP_PREFIXES = (
    "<command-message",
    "<command-name",
    "<task-notification",
    "<local-command",
    "<system-reminder",
    "<user_info",
    "<recommended_plugins",
    "Caveat:",
    "Base directory for this skill",
    "Headless pr-watch daemon wake:",
)
DEBRIEF_PROMPT_PREFIX = "Read the agent session transcript at "
DEBRIEF_PROMPT_MARK = "Extract ONLY durable learnings"
USER_QUERY_RE = re.compile(r"<user_query>\s*(.*?)\s*</user_query>", re.DOTALL)
SECRET_RE = re.compile(r"api[_-]?key|Bearer |sk-|xox[baprs]-", re.I)
FRAC_RE = re.compile(r"(\.\d{6})\d+")
SNIPPET_CHARS = 240
TITLE_CHARS = 120
LIVE_HOURS = 8
LIVE_LIMIT = 50
MAX_TRANSCRIPT_SIZE_MB = 50  # Skip files larger than this


def text_blocks(content, allowed):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "".join(
        block.get("text", "")
        for block in content
        if isinstance(block, dict) and block.get("type") in allowed
    )


def grok_text(content, role):
    text = text_blocks(content, TEXT_TYPES)
    if role != "user":
        return text
    match = USER_QUERY_RE.search(text)
    return match.group(1) if match else text


def turn(item):
    kind = item.get("type")
    if kind == "response_item":
        payload = item.get("payload") or {}
        if payload.get("type") != "message" or payload.get("role") not in {"user", "assistant"}:
            return None, None
        return payload["role"], text_blocks(payload.get("content"), TEXT_TYPES)
    if kind in GROK_SKIP_TYPES:
        return None, None
    role = item.get("role")
    message = item.get("message")
    if role in {"user", "assistant"} and isinstance(message, dict):
        return role, text_blocks(message.get("content"), TEXT_TYPES)
    if kind in {"user", "assistant"}:
        if isinstance(message, dict):
            return kind, text_blocks(message.get("content"), TEXT_TYPES)
        return kind, grok_text(item.get("content"), kind)
    return None, None


def is_debrief_extractor(text):
    return text.startswith(DEBRIEF_PROMPT_PREFIX) and DEBRIEF_PROMPT_MARK in text


def accepted_turn(item):
    if not isinstance(item, dict):
        return None, None
    role, text = turn(item)
    if role is None:
        return None, None
    text = text.strip()
    if (
        not text
        or text.startswith(SKIP_PREFIXES)
        or "tool_result" in text[:80]
        or is_debrief_extractor(text)
    ):
        return None, None
    return role, text


def conversation(path):
    with path.open(errors="replace") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            role, text = accepted_turn(item)
            if role is None:
                continue
            yield role, text


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    text = FRAC_RE.sub(r"\1", value.replace("Z", "+00:00"))
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def file_mtime(path):
    return dt.datetime.fromtimestamp(path.stat().st_mtime, tz=dt.timezone.utc)


def grok_meta(path):
    newest = None
    created = None
    cwd = ""
    title = ""
    summary_path = path.with_name("summary.json")
    if summary_path.is_file():
        try:
            data = json.loads(summary_path.read_text(errors="replace"))
        except (json.JSONDecodeError, ValueError, OSError):
            data = {}
        if isinstance(data, dict):
            created = parse_time(data.get("created_at"))
            newest = (
                parse_time(data.get("last_active_at"))
                or parse_time(data.get("updated_at"))
                or created
            )
            info = data.get("info")
            if isinstance(info, dict):
                cwd = info.get("cwd") or ""
            for key in ("generated_title", "session_summary", "last_turn_summary"):
                value = data.get(key)
                if isinstance(value, str) and value.strip():
                    title = value
                    break
    if newest is None:
        newest = file_mtime(path)
    return newest, path.parent.name, cwd, title, created


def cursor_project_cwd(path):
    parts = path.parts
    try:
        index = parts.index("projects")
    except ValueError:
        return ""
    if index + 1 >= len(parts):
        return ""
    remaining = parts[index + 1]
    current = Path("/")
    while remaining:
        try:
            children = [child for child in current.iterdir() if child.is_dir()]
        except OSError:
            return ""
        best = None
        for child in children:
            name = child.name
            if remaining == name or remaining.startswith(f"{name}-"):
                if best is None or len(name) > len(best.name):
                    best = child
        if best is None:
            return ""
        if remaining == best.name:
            return str(best)
        remaining = remaining[len(best.name) + 1 :]
        current = best
    return str(current)


def session_title(raw, messages):
    text = raw if isinstance(raw, str) else ""
    if not text.strip():
        for role, message in messages:
            if role == "user":
                text = message
                break
    text = collapse(text)
    if not text or looks_secret(text):
        return ""
    return text[:TITLE_CHARS]


def read_session(path, agent):
    newest = None
    created = None
    session = path.stem
    cwd = ""
    title = ""
    if agent == "grok":
        newest, session, cwd, title, created = grok_meta(path)
    elif agent == "cursor":
        session = path.parent.name
        if session == "agent-transcripts" or "agent-data" in path.parts or "cloud-agent-transcripts" in path.parts:
            session = path.stem
        newest = file_mtime(path)
        cwd = cursor_project_cwd(path)
    messages = []
    with path.open(errors="replace") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if not isinstance(item, dict):
                continue
            timestamp = parse_time(item.get("timestamp"))
            if agent in {"claude", "codex"} and created is None and timestamp:
                created = timestamp
            if timestamp and (newest is None or timestamp > newest):
                newest = timestamp
            payload = item.get("payload") or {}
            if item.get("type") == "session_meta":
                session = payload.get("id") or payload.get("session_id") or session
                cwd = payload.get("cwd") or cwd
                for key in ("title", "name"):
                    value = payload.get(key)
                    if isinstance(value, str) and value.strip():
                        title = value
            if item.get("type") == "ai-title":
                value = item.get("aiTitle")
                if isinstance(value, str) and value.strip():
                    title = value
            if agent != "grok":
                session = item.get("sessionId") or session
            cwd = item.get("cwd") or cwd
            role, text = accepted_turn(item)
            if role is not None:
                messages.append((role, text))
    return newest, session, cwd, messages, session_title(title, messages), created


def inspect(path, agent):
    newest, session, cwd, messages, title, _created = read_session(path, agent)
    substantive = any(role == "user" for role, _ in messages)
    return newest, session, cwd, len(messages), substantive, title


def home_dir():
    override = os.environ.get("SESSION_TRANSCRIPTS_HOME")
    if override:
        return Path(override)
    return Path.home()


def cloud_transcript_root():
    override = os.environ.get("SESSION_TRANSCRIPTS_CLOUD_ROOT")
    if override:
        return Path(override)
    return Path("/tmp/cursor/cloud-agent-transcripts")


def paths_for(agent):
    home = home_dir()
    if agent in {"all", "codex"}:
        yield from home.glob(".codex/sessions/**/*.jsonl")
    if agent in {"all", "claude"}:
        yield from (
            path
            for path in home.glob(".claude/projects/**/*.jsonl")
            if "subagents" not in path.parts
        )
    if agent in {"all", "grok"}:
        yield from home.glob(".grok/sessions/**/chat_history.jsonl")
    if agent in {"all", "cursor"}:
        yield from home.glob(".cursor/projects/**/agent-transcripts/**/*.jsonl")
        # Agent hosts may also export transcripts under agent-data.
        yield from home.glob("agent-data/agent-transcripts/**/*.jsonl")
        # Cloud agent transcripts fetched via cursor-cloud MCP tools
        cloud_root = cloud_transcript_root()
        if cloud_root.exists():
            for path in cloud_root.glob("**/transcript.json"):
                size_mb = path.stat().st_size / (1024 * 1024)
                if size_mb <= MAX_TRANSCRIPT_SIZE_MB:
                    yield path


def agent_for(path):
    parts = path.parts
    if ".grok" in parts:
        return "grok"
    if ".cursor" in parts or "agent-data" in parts or "cloud-agent-transcripts" in parts:
        return "cursor"
    if ".codex" in parts:
        return "codex"
    if ".claude" in parts:
        return "claude"
    return "unknown"


def looks_secret(text):
    return bool(SECRET_RE.search(text))


def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def cutoff_from(since_hours):
    if since_hours is None:
        return None
    return utc_now() - dt.timedelta(hours=since_hours)


def in_window(newest, cutoff):
    if cutoff is None:
        return True
    if newest is None:
        return False
    return newest.astimezone(dt.timezone.utc) >= cutoff


def membership_ts(agent, newest, created, *, harvest):
    # list/search --since-hours: Grok created_at. live stays last_active.
    if harvest and agent == "grok" and created is not None:
        return created
    return newest


def tsv_field(value):
    return collapse(value) if value else "-"


def iter_rows(agent, since_hours, *, harvest=False):
    cutoff = cutoff_from(since_hours)
    rows = []
    for path in paths_for(agent):
        found = agent_for(path)
        newest, session, cwd, messages, title, created = read_session(path, found)
        if not in_window(membership_ts(found, newest, created, harvest=harvest), cutoff):
            continue
        when = newest or dt.datetime.min.replace(tzinfo=dt.timezone.utc)
        substantive = any(role == "user" for role, _ in messages)
        rows.append((when, found, session, cwd, title, len(messages), substantive, path, created))
    rows.sort(reverse=True)
    return rows


def in_workspace(cwd, workspace):
    if not workspace:
        return True
    if not cwd or not Path(cwd).is_absolute():
        return False
    root = Path(workspace).expanduser().resolve()
    directory = Path(cwd).resolve()
    return directory == root or root in directory.parents


def list_sessions(args):
    for newest, agent, session, cwd, title, messages, substantive, path, created in iter_rows(
            args.agent, args.since_hours, harvest=True):
        if not in_workspace(cwd, getattr(args, "workspace", None)):
            continue
        print("\t".join((
            newest.isoformat(),
            agent,
            session,
            tsv_field(title),
            str(messages),
            "substantive" if substantive else "automation",
            cwd,
            str(path),
            created.isoformat() if created else "",
        )))


def live_sessions(args):
    shown = 0
    for newest, agent, session, cwd, title, _messages, substantive, _path, _created in iter_rows(args.agent, args.since_hours):
        if not args.include_automation and not substantive:
            continue
        print("\t".join((
            newest.isoformat(),
            agent,
            session,
            tsv_field(cwd),
            tsv_field(title),
        )))
        shown += 1
        if args.limit is not None and shown >= args.limit:
            break


def extract(args):
    path = Path(args.path).expanduser().resolve()
    for role, text in conversation(path):
        if looks_secret(text):
            continue
        label = "USER" if role == "user" else "ASST"
        rendered = text if args.full else text.replace("\n", " ")[: args.max_chars]
        print(f"{label}: {rendered}")


def first_snippet(texts, terms):
    for text in texts:
        low = text.lower()
        if all(term in low for term in terms):
            return collapse(text)[:SNIPPET_CHARS]
    for text in texts:
        low = text.lower()
        if any(term in low for term in terms):
            return collapse(text)[:SNIPPET_CHARS]
    return ""


def search_sessions(args):
    terms = [term.lower() for term in args.terms]
    hits = []
    cutoff = cutoff_from(args.since_hours)
    for path in paths_for(args.agent):
        found = agent_for(path)
        newest, session, cwd, messages, _title, created = read_session(path, found)
        if not in_window(membership_ts(found, newest, created, harvest=True), cutoff):
            continue
        visible = [text for _role, text in messages if not looks_secret(text)]
        blob = "\n".join(visible).lower()
        if not all(term in blob for term in terms):
            continue
        snippet = first_snippet(visible, terms)
        if not snippet:
            continue
        when = newest or dt.datetime.min.replace(tzinfo=dt.timezone.utc)
        hits.append((when, found, session, cwd or "-", path, snippet))
    hits.sort(reverse=True)
    for newest, agent, session, cwd, path, snippet in hits[: args.max_hits]:
        print("\t".join((
            newest.isoformat(),
            agent,
            session,
            cwd,
            str(path),
            snippet,
        )))


TOKEN_FIELDS = ("input_tokens", "cached_input_tokens", "output_tokens",
                "reasoning_output_tokens", "total_tokens")


def token_counts(usage):
    if not isinstance(usage, dict):
        raise ValueError("missing token usage counts")
    counts = {key: usage.get(key) for key in TOKEN_FIELDS}
    if any(type(value) is not int or value < 0 for value in counts.values()):
        raise ValueError("invalid token usage counts")
    if counts["cached_input_tokens"] > counts["input_tokens"]:
        raise ValueError("cached input exceeds input tokens")
    counts["uncached_input_tokens"] = counts["input_tokens"] - counts["cached_input_tokens"]
    return counts


def codex_usage(args):
    """Read native per-response counters; cumulative snapshots are checks only."""
    responses = {}
    cumulative = None
    with Path(args.path).expanduser().open() as handle:
        for line_number, line in enumerate(handle, 1):
            try:
                item = json.loads(line)
            except ValueError:
                raise ValueError(f"invalid JSON at line {line_number}") from None
            if not isinstance(item, dict) or item.get("type") != "token_usage_record":
                continue
            payload = item.get("payload") or {}
            if not isinstance(payload, dict):
                raise ValueError("invalid token usage payload")
            if payload.get("turn_id") != args.turn_id:
                continue
            response_id = payload.get("response_id")
            if not isinstance(response_id, str) or not response_id:
                raise ValueError("token usage record lacks a response ID")
            counts = token_counts(payload.get("usage"))
            if response_id in responses and responses[response_id] != counts:
                raise ValueError("conflicting usage for a repeated response ID")
            responses[response_id] = counts
            if payload.get("turn_token_usage") is not None:
                cumulative = token_counts(payload["turn_token_usage"])
    if not responses:
        raise ValueError("no native token usage records for the requested turn")
    totals = {key: sum(counts[key] for counts in responses.values())
              for key in next(iter(responses.values()))}
    result = {"turn_id": args.turn_id, "response_count": len(responses),
              "usage": totals,
              "responses": [{"response_id": key, "usage": counts}
                            for key, counts in responses.items()],
              "turn_token_usage_matches": None if cumulative is None else totals == cumulative}
    print(json.dumps(result, sort_keys=True))
    if cumulative is not None and totals != cumulative:
        raise ValueError("per-response sum differs from the last turn_token_usage snapshot")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    usage = commands.add_parser("usage", help="native Codex token counts for one turn")
    usage.add_argument("path")
    usage.add_argument("--turn-id", required=True)
    usage.set_defaults(run=codex_usage)
    listing = commands.add_parser("list")
    listing.add_argument("--agent", choices=AGENTS, default="all")
    listing.add_argument("--since-hours", type=float)
    listing.add_argument("--workspace", help="include only sessions from this directory or its children")
    listing.set_defaults(run=list_sessions)
    living = commands.add_parser("live")
    living.add_argument("--agent", choices=AGENTS, default="all")
    living.add_argument("--since-hours", type=float, default=LIVE_HOURS)
    living.add_argument("--limit", type=int, default=LIVE_LIMIT)
    living.add_argument("--include-automation", action="store_true")
    living.set_defaults(run=live_sessions)
    extracting = commands.add_parser("extract")
    extracting.add_argument("path")
    extracting.add_argument("--full", action="store_true")
    extracting.add_argument("--max-chars", type=int, default=500)
    extracting.set_defaults(run=extract)
    searching = commands.add_parser("search")
    searching.add_argument("--agent", choices=AGENTS, default="all")
    searching.add_argument("--since-hours", type=float)
    searching.add_argument("--max-hits", type=int, default=50)
    searching.add_argument("terms", nargs="+")
    searching.set_defaults(run=search_sessions)
    args = parser.parse_args()
    try:
        args.run(args)
    except BrokenPipeError:
        pass
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
