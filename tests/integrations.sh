#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid

# A remote's default branch can have another name. Local edits survive the pull.
export MANAGER_REPOS="$tmp/repos"
mkdir "$MANAGER_REPOS"
git init -q --bare -b trunk "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/upstream" 2>/dev/null
git -C "$tmp/upstream" commit --allow-empty -qm init
git -C "$tmp/upstream" push -qu origin trunk
git clone -q "$tmp/origin.git" "$MANAGER_REPOS/checkout"
touch "$MANAGER_REPOS/checkout/untracked"
git -C "$tmp/upstream" commit --allow-empty -qm change
git -C "$tmp/upstream" push -q
"$root/plugins/repo-freshness/run"
test "$(git -C "$MANAGER_REPOS/checkout" rev-parse HEAD)" = "$(git -C "$tmp/upstream" rev-parse HEAD)"
test -e "$MANAGER_REPOS/checkout/untracked"
git -C "$MANAGER_REPOS/checkout" checkout -qb task
git -C "$tmp/upstream" commit --allow-empty -qm change2
git -C "$tmp/upstream" push -q
"$root/plugins/repo-freshness/run"
test "$(git -C "$MANAGER_REPOS/checkout" rev-parse trunk)" = "$(git -C "$tmp/upstream" rev-parse HEAD)"
test "$(git -C "$MANAGER_REPOS/checkout" branch --show-current)" = task

mkdir "$tmp/bin" "$tmp/work space"
export PATH="$tmp/bin:$PATH" MANAGER_CLI="$tmp/bin/manager"
export MANAGER_REVIEW_REPOS=example/project
cat > "$tmp/bin/gh" <<'SH'
#!/bin/sh
case "$*" in
  *"/pulls?"*) printf '7\t%040d\t%040d\n' 1 2 ;;
  *"/compare/"*) echo 'diff --git a/x b/x' ;;
  *) exit 2 ;;
esac
SH
cat > "$MANAGER_CLI" <<'SH'
#!/bin/sh
read -r first
if [ "$first" = failing ]; then exit 3; fi
cat >/dev/null
printf '%s\n' "$first"
SH
chmod +x "$tmp/bin/"*
"$root/plugins/github-review/run"
receipt="$XDG_STATE_HOME/manager/github-review/example/project/7/$(printf '%040d' 2).md"
grep -q 'PR #7' "$receipt"
test -z "$("$root/plugins/github-review/run")"

export MANAGER_BRIEFS_CATALOG="$tmp/catalog.json"
cat > "$MANAGER_BRIEFS_CATALOG" <<'JSON'
[{"name":"first","workspace":"work space","every_seconds":60,"brief":"one.md"},
 {"name":"second","workspace":"work space","every_seconds":60,"brief":"two.md"}]
JSON
printf 'first brief\n' > "$tmp/one.md"
printf 'failing\n' > "$tmp/two.md"
"$root/plugins/scheduled-briefs/run"
grep -qx 'first brief' "$XDG_STATE_HOME/manager/scheduled-briefs/first/result.md"
if "$root/plugins/scheduled-briefs/run"; then exit 1; fi
test ! -e "$XDG_STATE_HOME/manager/scheduled-briefs/second/result.md"
echo second > "$tmp/two.md"
"$root/plugins/scheduled-briefs/run"
grep -qx second "$XDG_STATE_HOME/manager/scheduled-briefs/second/result.md"
test -z "$("$root/plugins/scheduled-briefs/run")"
