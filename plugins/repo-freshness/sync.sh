# The caller supplies freshness_log and can define a freshness_updated callback.
sync_repo() {
  local repo="$1" branch before after behind
  local remote="${2:-origin}" target="${3:-}"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$repo" fetch "$remote" --prune >/dev/null 2>&1 || { freshness_log "$repo fetch FAILED"; return 1; }
  if [[ -z "$target" ]]; then
    target="$(git -C "$repo" symbolic-ref --short "refs/remotes/$remote/HEAD")" || return 1
    target="${target#"$remote"/}"
  fi
  branch="$(git -C "$repo" branch --show-current)"
  if [[ "$branch" != "$target" ]]; then
    git -C "$repo" fetch "$remote" "$target:$target" >/dev/null 2>&1 &&
      freshness_log "$repo updated local $target ref" || freshness_log "$repo local $target not ff-able; left alone"
    return 0
  fi
  before="$(git -C "$repo" rev-parse HEAD)" || return 1
  if git -C "$repo" merge --ff-only "$remote/$target" >/dev/null 2>&1; then
    freshness_log "$repo ff-pulled $target"
    after="$(git -C "$repo" rev-parse HEAD)" || return 1
    if [[ "$before" != "$after" ]] && declare -F freshness_updated >/dev/null; then
      freshness_updated "$repo"
    fi
  else
    behind="$(git -C "$repo" rev-list --count "HEAD..$remote/$target" 2>/dev/null || echo '?')"
    freshness_log "$repo $target not fast-forwardable (dirty or diverged), $behind behind; left alone"
    if [[ "${REPO_FRESHNESS_REPORT:-0}" == 1 && "$behind" != 0 ]]; then
      echo "repo-freshness: ${repo%/} $target is $behind commits behind $remote/$target and cannot fast-forward (local edits or divergence). Read instructions with git show $remote/$target:<path>."
    fi
  fi
}
