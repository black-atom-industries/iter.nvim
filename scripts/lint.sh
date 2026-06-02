#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$dir")"
outfile="${TMPDIR:-$TEMPDIR:-/tmp}/flux_lint_$$.json"

cleanup() {
  rm -f "$outfile"
}
trap cleanup EXIT

# --check always exits non-zero when diagnostics are found. Ignore that.
lua-language-server \
  --configpath="$project_dir/.luarc.json" \
  --check="$project_dir" \
  --check_format=json \
  --check_out_path="$outfile" \
  >/dev/null 2>&1 || true

python3 "$dir/_parse_lint.py" "$outfile" "$project_dir"
