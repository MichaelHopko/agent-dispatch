#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log.sh"
root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT
log="$root/evidence/decisions.tsv"
if bash "$script" "$log" >/dev/null 2>&1; then
  echo 'FAIL: wrong argument count accepted' >&2
  exit 1
fi
[ ! -e "$log" ]
bash "$script" "$log" build 'keep change' 'measured improvement' 'receipt.txt' kept
bash "$script" "$log" $'bad\tphase' $'=HYPERLINK("bad")' $'+sum\nnew\rline' '-cmd' '@user'
python3 - "$log" <<'PY'
import csv
import re
import sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text()
rows = list(csv.reader(raw.splitlines(), delimiter='\t'))
assert rows[0] == ['ts', 'phase', 'decision', 'why', 'evidence', 'result'], rows
assert len(rows) == 3 and all(len(row) == 6 for row in rows), rows
assert rows[1][1:] == ['build', 'keep change', 'measured improvement', 'receipt.txt', 'kept'], rows
assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', rows[1][0]), rows
assert rows[2][1] == 'bad phase', rows
assert rows[2][2:] == ['\'=HYPERLINK("bad")', "'+sum new line", "'-cmd", "'@user"], rows
print('PASS: usage, nested creation, append, timestamp, TSV normalization and formula escaping')
PY
