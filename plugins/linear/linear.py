#!/usr/bin/env python3
"""File verified findings in Linear and process this installation's queued issues."""
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "lib"))
from linear_intake import ISSUE_FIELDS, dup_prompt, find_related, missing_entity

TICKET_RE = re.compile(r"\b[A-Z][A-Z0-9]*-\d+\b")
def graphql(query, variables):
    token = os.environ.get("LINEAR_API_KEY")
    if not token:
        raise ValueError("Set LINEAR_API_KEY for the Linear plugin")
    request = urllib.request.Request("https://api.linear.app/graphql",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        try:
            error = json.load(exc).get("errors", [{}])[0].get("message")
        except (ValueError, IndexError, AttributeError):
            error = None
        raise RuntimeError(error or f"Linear HTTP {exc.code}") from exc
    if payload.get("errors") or not payload.get("data"):
        raise RuntimeError(str(payload.get("errors") or "Linear returned no data"))
    return payload["data"]


def team():
    key = os.environ.get("MANAGER_LINEAR_TEAM", "")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key):
        raise ValueError("Set MANAGER_LINEAR_TEAM to your Linear team's identifier")
    nodes = graphql("query($key:String!){teams(filter:{key:{eq:$key}}){nodes{id key states{nodes{id type name}}}}}",
                    {"key": key.upper()})["teams"]["nodes"]
    if len(nodes) != 1:
        raise ValueError("Expected one accessible team: " + key)
    return nodes[0]


@contextlib.contextmanager
def registry(team_id):
    base = Path(os.getenv("XDG_STATE_HOME", Path.home() / ".local/state")) / "manager/linear" / str(uuid.UUID(team_id))
    scope = os.getenv("MANAGER_LINEAR_SCOPE")
    if not scope:
        roots = {str(Path(os.environ[name]).resolve()) for name in
                 ("MANAGER_LEARNINGS_WORKSPACE", "MANAGER_TICKET_WORKSPACE") if os.getenv(name)}
        if len(roots) != 1:
            raise ValueError("Set one workspace for learning and execution, or name their shared MANAGER_LINEAR_SCOPE")
        scope = roots.pop()
    base /= hashlib.sha256(os.fsencode(scope)).hexdigest()
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (base / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with contextlib.closing(sqlite3.connect(base / "queue.db", isolation_level=None)) as db:
            db.row_factory = sqlite3.Row
            db.execute("""CREATE TABLE IF NOT EXISTS findings (
                key TEXT PRIMARY KEY, action TEXT, issue_id TEXT, identifier TEXT,
                status TEXT, day TEXT, attempt TEXT, receipt TEXT, operation_id TEXT)""")
            yield db


def decision(prompt):
    cli = os.environ.get("MANAGER_CLI", str(HERE.parents[1] / "manager"))
    env = os.environ.copy()
    env.pop("LINEAR_API_KEY", None)
    with tempfile.TemporaryDirectory() as cwd:
        out = subprocess.run([cli, "run"], input=prompt, text=True, capture_output=True,
                             cwd=cwd, env=env, timeout=600, check=True)
    return json.loads(out.stdout.strip())["duplicate_of"]


def mutation(query, variables, field):
    payload = graphql(query, variables)[field]
    if not payload.get("success"):
        raise RuntimeError("Linear rejected " + field)
    return payload


def lookup(kind, remote_id):
    fields = ISSUE_FIELDS + " team { id } assignee { id }" if kind == "issue" else "id issue { id }"
    try:
        return graphql("query($id:String!){" + kind + "(id:$id){" + fields + "}}", {"id": remote_id})[kind]
    except RuntimeError as exc:
        if missing_entity(exc):
            return None
        raise


def comment(issue, comment_id, text):
    previous = lookup("comment", comment_id)
    if previous:
        if previous["issue"]["id"] != issue:
            raise RuntimeError("Comment belongs to another issue")
        return
    mutation("mutation($input:CommentCreateInput!){commentCreate(input:$input){success}}",
             {"input": {"id": comment_id, "issueId": issue, "body": text}}, "commentCreate")


def intake(db, target, candidate):
    for field in ("key", "title", "body", "evidence"):
        if not isinstance(candidate.get(field), str) or not candidate[field].strip():
            raise ValueError("Missing finding field: " + field)
    key = candidate["key"]
    row = db.execute("SELECT * FROM findings WHERE key=?", (key,)).fetchone()
    if row and row["status"] != "filing":
        return row["identifier"]
    if not row:
        tickets = find_related(graphql, target["key"], candidate["title"], candidate["body"], candidate["evidence"], RuntimeError, TICKET_RE)
        match = None
        if tickets:
            ident = decision(dup_prompt(candidate, tickets))
            if ident is not None:
                match = next((t for t in tickets if t["identifier"] == ident), None)
                if not match:
                    raise ValueError("Deduplication returned an unknown ticket")
        day = dt.datetime.now(dt.timezone.utc).date().isoformat()
        count = db.execute("SELECT COUNT(*) FROM findings WHERE action='create' AND day=?", (day,)).fetchone()[0]
        if not match and count >= int(os.getenv("MANAGER_LINEAR_DAILY_CAP", "3")):
            raise RuntimeError("Daily filing cap reached; retry the pending finding later")
        operation_id = str(uuid.uuid4())
        db.execute("INSERT INTO findings(key,action,issue_id,identifier,status,day,operation_id) VALUES(?,?,?,?,?,?,?)",
                   (key, "comment" if match else "create", match["id"] if match else operation_id,
                    match["identifier"] if match else None, "filing", day, operation_id))
        row = db.execute("SELECT * FROM findings WHERE key=?", (key,)).fetchone()
    if row["action"] == "comment":
        comment(row["issue_id"], row["operation_id"],
                f"New evidence for {candidate['title']}\n\n{candidate['evidence']}")
        status, ident = "linked", row["identifier"]
    else:
        created = lookup("issue", row["issue_id"])
        if not created:
            data = {"id": row["issue_id"], "teamId": target["id"], "title": candidate["title"],
                    "description": candidate["body"] + "\n\nEvidence: " + candidate["evidence"]}
            created = mutation("mutation($input:IssueCreateInput!){issueCreate(input:$input){success issue{identifier}}}",
                               {"input": data}, "issueCreate")["issue"]
        status, ident = "ready", created["identifier"]
    db.execute("UPDATE findings SET status=?,identifier=? WHERE key=?", (status, ident, key))
    return ident


def claim(db, target, directory):
    verifier = os.environ.get("MANAGER_TICKET_VERIFY", "")
    if not verifier or not os.access(verifier, os.X_OK) or not Path(verifier).is_absolute():
        raise ValueError("Set MANAGER_TICKET_VERIFY to an absolute executable verifier")
    for row in db.execute("SELECT * FROM findings WHERE status='ready' ORDER BY rowid").fetchall():
        issue = lookup("issue", row["issue_id"])
        if not issue or issue["team"]["id"] != target["id"]:
            continue
        if issue["archivedAt"] or issue.get("assignee") or issue["state"]["type"] not in ("backlog", "unstarted"):
            continue
        token = str(uuid.uuid4())
        goal = issue["title"] + "\n\n" + (issue["description"] or "")
        for name, text in [("id", issue["identifier"]), ("attempt", token), ("goal", goal)]:
            (directory / name).write_text(text)
        db.execute("UPDATE findings SET status='active',attempt=? WHERE key=?", (token, row["key"]))
        return


def finish(db, target, directory, event):
    token = (directory / "attempt").read_text()
    row = db.execute("SELECT * FROM findings WHERE attempt=?", (token,)).fetchone()
    if not row or row["identifier"] != (directory / "id").read_text():
        raise ValueError("Unknown worker attempt")
    if row["status"] == "done":
        return
    if row["status"] not in ("active", "verified"):
        raise ValueError("Worker attempt is no longer active")
    if event == "failed":
        db.execute("UPDATE findings SET status='failed' WHERE attempt=?", (token,))
        return
    receipt = row["receipt"]
    if not receipt:
        process = subprocess.run([os.environ["MANAGER_TICKET_VERIFY"], directory], capture_output=True, text=True)
        receipt = process.stdout.strip()
        if process.returncode or not receipt:
            db.execute("UPDATE findings SET status='failed' WHERE attempt=?", (token,))
            raise RuntimeError("Completion verifier did not return a successful evidence receipt")
        db.execute("UPDATE findings SET status='verified',receipt=? WHERE attempt=?", (receipt, token))
    deliver(db, target, row, receipt)


def deliver(db, target, row, receipt):
    current = lookup("issue", row["issue_id"])
    if not current or current["team"]["id"] != target["id"] or current["archivedAt"] or current["state"]["type"] == "canceled":
        raise RuntimeError("Issue moved, archived, or canceled before delivery; review its current state")
    states = [s for s in target["states"]["nodes"] if s["type"] == "completed"]
    requested = os.getenv("MANAGER_LINEAR_DONE_STATE")
    if requested:
        states = [s for s in states if s["name"] == requested]
    if len(states) != 1:
        raise ValueError("Select a completed workflow state using MANAGER_LINEAR_DONE_STATE")
    comment(row["issue_id"], row["attempt"], receipt)
    mutation("mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}",
             {"id": row["issue_id"], "input": {"stateId": states[0]["id"]}}, "issueUpdate")
    db.execute("UPDATE findings SET status='done' WHERE key=?", (row["key"],))


def main():
    args = sys.argv[1:]
    if len(args) not in (1, 2):
        raise ValueError("Usage: linear.py intake FILE | claim|complete|failed DIR | list | retry ID")
    action = args[0]
    target = team()
    with registry(target["id"]) as db:
        if action == "list" and len(args) == 1:
            for row in db.execute("SELECT identifier,status FROM findings ORDER BY rowid"):
                print(row["identifier"], row["status"])
        elif action == "intake" and len(args) == 2:
            findings = json.loads(Path(args[1]).read_text())
            if not isinstance(findings, list):
                raise ValueError("Expected an array of findings")
            for candidate in findings:
                print(intake(db, target, candidate))
        elif action == "claim" and len(args) == 2:
            for row in db.execute("SELECT * FROM findings WHERE status='verified'").fetchall():
                deliver(db, target, row, row["receipt"])
            claim(db, target, Path(args[1]))
        elif action in ("complete", "failed") and len(args) == 2:
            finish(db, target, Path(args[1]), action)
        elif action == "retry" and len(args) == 2:
            cur = db.execute("UPDATE findings SET status='ready',attempt=NULL WHERE identifier=? AND status IN ('failed','active')",
                             (args[1],))
            if cur.rowcount != 1:
                raise ValueError("Expected one failed or interrupted worker")
        else:
            raise ValueError("Unknown Linear plugin command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        sys.exit(f"manager-linear: {exc}")
