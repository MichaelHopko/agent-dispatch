#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prefix="$tmp/CLI tools"
config="$tmp/config"
mkdir -p "$config/grok" "$tmp/workspace"
export OPENCLAW_STATE_DIR="$tmp/openclaw"
export QUOTA_DISPATCH_CONFIG="$config" QUOTA_DISPATCH_STATE="$tmp/state"
export MANAGER_CONFIG="$tmp/manager-config" XDG_STATE_HOME="$tmp/xdg"
printf 'grok\n' > "$config/order"
cat > "$config/grok/run" <<'ADAPTER'
#!/usr/bin/env bash
set -eu
if [ "$#" -gt 0 ]; then
    printf '%s' "$1"
else
    cat
fi
ADAPTER
chmod +x "$config/grok/run"

HOME="$tmp/home" "$root/install.sh"
test ! -e "$OPENCLAW_STATE_DIR"
test ! -e "$tmp/home/.openclaw"
test "$("$tmp/home/.local/bin/manager" run --agent grok "Standalone goal")" = "Standalone goal"

"$root/install.sh" --prefix "$prefix" --openclaw
"$root/install.sh" --prefix "$prefix" --openclaw
# Exercise the exact installed skill command without importing the user's PATH prefix.
cd "$tmp/workspace"
python3 - "$OPENCLAW_STATE_DIR/skills/manager-cli/SKILL.md" <<'PY'
from pathlib import Path
import re
import shlex
import subprocess
import sys
text = Path(sys.argv[1]).read_text()
exe = shlex.split(re.search(r"^Executable: `(.+)`$", text, re.M)[1])
goal = "A task with spaces, quotes, and $variables"
assert subprocess.check_output([*exe, "run", "--agent", "grok", goal], text=True) == goal
assert subprocess.check_output([*exe, "run"], input="multiline\nbrief\n", text=True) == "multiline\nbrief\n"
PY
test -x "$prefix/bin/manager"
test -L "$prefix/bin/dispatch"
test "$("$prefix/bin/dispatch" pick)" = grok
echo edited >> "$OPENCLAW_STATE_DIR/skills/manager-cli/SKILL.md"
if "$root/install.sh" --prefix "$prefix" --openclaw; then exit 1; fi
grep -qx edited "$OPENCLAW_STATE_DIR/skills/manager-cli/SKILL.md"
mkdir -p "$tmp/collision/bin"
echo existing > "$tmp/collision/bin/dispatch"
if "$root/install.sh" --prefix "$tmp/collision"; then exit 1; fi
test ! -e "$tmp/collision/bin/manager"
grep -qx existing "$tmp/collision/bin/dispatch"
printf 'Manager install and caller handoff passed.\n'
