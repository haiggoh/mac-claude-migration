#!/bin/bash
# Repo-owned version-consistency gate: VERSION is the single source and the
# CHANGELOG top entry must agree. run-to-completion's rtc-ship.sh runs this
# file instead of its built-in surface check when it is present and executable.
# Usage: test_version_consistency.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
[ "${1:-}" = "--help" ] && { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
v=$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo "")
c=$(sed -n -E 's/^##+[[:space:]]+\[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$ROOT/CHANGELOG.md" 2>/dev/null | head -1)
if [ -z "$v" ] || [ -z "$c" ]; then
  echo "✖ could not read VERSION or the CHANGELOG top entry" >&2
  exit 1
fi
if [ "$v" != "$c" ]; then
  echo "✖ VERSION=$v but CHANGELOG top entry=$c" >&2
  exit 1
fi
echo "ok VERSION=$v agrees with CHANGELOG top entry $c"
exit 0
