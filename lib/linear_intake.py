"""Search a Linear team for equivalent work before filing a finding."""
import re

WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{3,}")
STOP = frozenset(
    "this that with from have been were will when what which there their about into "
    "after before again should would could does done only also than then them they "
    "agent agents ticket tickets failing failed fails error errors keep keeps runs "
    "main repeated".split()
)
ISSUE_FIELDS = "id identifier title description state { name type } archivedAt"


def missing_entity(error):
    return any(message in str(error).lower() for message in ("not found", "could not find"))


def search_terms(title, body):
    words = [w for w in WORD_RE.findall(title) if w.lower() not in STOP]
    terms = [title]
    if len(words) >= 2:
        terms.append(" ".join(words[:4]))
    long_words = sorted({w for w in words if len(w) >= 7}, key=len, reverse=True)
    terms.extend(long_words[:2])
    seen, out = set(), []
    for t in terms:
        if t and t.lower() not in seen:
            seen.add(t.lower())
            out.append(t)
    return out[:4]


def find_related(graphql, team, title, body, evidence, missing_errors, ticket_re):
    found = {}
    for term in search_terms(title, body):
        data = graphql(
            "query($t: String!, $k: String!) { searchIssues(term: $t, includeArchived: true, first: 8,"
            " filter: { team: { key: { eq: $k } } }) { nodes { " + ISSUE_FIELDS + " } } }",
            {"t": term, "k": team},
        )
        for node in (data.get("searchIssues") or {}).get("nodes") or []:
            found.setdefault(node["identifier"], node)
    for ident in sorted(set(m.group(0) for m in ticket_re.finditer(f"{title}\n{body}\n{evidence}"))):
        if ident in found or not ident.startswith(team + "-"):
            continue
        try:
            data = graphql("query($id: String!) { issue(id: $id) { " + ISSUE_FIELDS + " } }", {"id": ident})
        except missing_errors as exc:
            if missing_entity(exc):
                continue
            raise
        if data.get("issue"):
            found[ident] = data["issue"]
    return list(found.values())[:15]


def dup_prompt(cand, tickets):
    listing = "\n\n".join(
        f"[{t['identifier']}] ({(t.get('state') or {}).get('name', '?')}"
        f"{', archived' if t.get('archivedAt') else ''}) {t['title']}\n"
        f"{(t.get('description') or '').strip()[:600]}"
        for t in tickets
    )
    return f"""You deduplicate a Linear backlog. Do not run tools or edit files; answer from this text only.

Candidate ticket:
Title: {cand['title']}
{cand['body'][:2500]}

Existing tickets (open, finished and canceled):
{listing}

Is the candidate the same piece of work as one existing ticket: the same problem or request,
so that doing or having done that ticket covers it? Sharing a topic, a file or a keyword is
not enough. A finished ticket counts when the candidate is the same problem coming back.
Reply with one JSON object and nothing after it:
{{"duplicate_of": "<identifier or null>", "reason": "<one sentence>"}}"""
