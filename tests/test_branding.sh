#!/bin/bash
# Branding (emoji rollout Task 21): the About mark 📦 leads both scripts' --help
# banner first line and the README h1.
#
# Usage: test_branding.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

for s in backup.sh restore.sh; do
  first=$("$ROOT/$s" --help 2>&1 | sed -n '1p')
  if printf '%s' "$first" | grep -q "^📦 $s "; then
    ok "$s --help banner leads with 📦"
  else bad "$s banner" "first line is: $first"; fi
done

readme_first=$(sed -n '1p' "$ROOT/README.md")
if [ "$readme_first" = "# 📦 mac-claude-migration" ]; then
  ok "README h1 exact"
else bad "README h1" "first line is: $readme_first"; fi

echo "branding: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
