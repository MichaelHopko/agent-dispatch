#!/usr/bin/env bash
# Usage: tests/install-openclaw.sh /path/to/node_modules/openclaw
set -euo pipefail
package=$(cd "${1:?Pass the installed openclaw package directory}" && pwd -P)
root=$(cd "$(dirname "$0")/.." && pwd -P)
version=$(node -p 'require(process.argv[1]).version' "$package/package.json")
if [[ "$version" != 2026.11.10 ]]; then
    echo "This native exec fixture targets OpenClaw 2026.11.10 (found $version)." >&2
    exit 2
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export OPENCLAW_STATE_DIR="$tmp/openclaw" OPENCLAW_CONFIG_PATH="$tmp/config.json"
export QUOTA_DISPATCH_CONFIG="$tmp/profiles" QUOTA_DISPATCH_STATE="$tmp/quota-state"
export MANAGER_CONFIG="$tmp/manager-config" XDG_STATE_HOME="$tmp/xdg"

cd "$tmp"
mkdir -p workspace profiles/replay
printf 'replay\n' > profiles/order
cat > profiles/replay/run <<'ADAPTER'
#!/bin/sh
printf 'MANAGER_HANDOFF:%s' "$1"
ADAPTER
chmod +x profiles/replay/run
"$root/install.sh" --prefix "$tmp/tools" --openclaw
python3 - <<'PY'
import json
from pathlib import Path
root = Path.cwd()
Path("config.json").write_text(json.dumps({"agents": {"defaults": {"workspace": str(root / "workspace")}}}))
cli = root / "tools/bin/manager"
policy = {"version": 1, "defaults": {"security": "allowlist", "ask": "off", "askFallback": "deny"},
          "agents": {"main": {"allowlist": [{"pattern": str(cli)}, {"pattern": str(cli.resolve())}]}}}
Path("approvals.json").write_text(json.dumps(policy))
PY
node "$package/openclaw.mjs" skills info manager-cli --json > skill.json
node "$package/openclaw.mjs" approvals set --file "$tmp/approvals.json" --json > /dev/null
node --input-type=module - "$package" <<'JS'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

// The CLI has no direct native exec subcommand. Use this version's tool factory
// so the replay exercises OpenClaw's real process, approval, and result handling.
const toolModule = join(process.argv[2], 'dist/bash-tools-B4Gg_ZJ4.mjs');
const {createExecTool} = await import(pathToFileURL(toolModule));
const info = JSON.parse(readFileSync('skill.json', 'utf8'));
assert.equal(info.name, 'manager-cli');
assert.equal(info.eligible, true);
assert.equal(info.source, 'openclaw-managed');
const doc = readFileSync(info.filePath, 'utf8');
const [, manager] = doc.match(/^Executable: `(.+)`$/m);
const cwd = join(process.cwd(), 'workspace');
const tool = createExecTool({agentId: 'main', cwd, host: 'gateway', ask: 'off', security: 'allowlist'});
const result = await tool.execute('manager-handoff', {
    command: manager + ' run --agent replay isolated-fixture',
    workdir: cwd,
    yieldMs: 15000,
});
assert.equal(result.details.status, 'completed');
assert.equal(result.details.exitCode, 0);
assert.equal(result.details.aggregated, 'MANAGER_HANDOFF:isolated-fixture');
assert.equal(result.details.cwd, cwd);
console.log('OpenClaw discovered the skill and executed Manager; the fixture returned its receipt.');
JS
