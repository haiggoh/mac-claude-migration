#!/bin/bash
# Run every test in this repo. Usage: run-all.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
[ "${1:-}" = "--help" ] && { sed -n '2,2p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
RC=0
echo "== CLI contract (args parsed before work) =="; "$HERE/test_cli_contract.sh"   || RC=1
echo; echo "== capture shapes (file vs directory) ==";  "$HERE/test_capture_shapes.sh" || RC=1
echo; echo "== portability (public-release contract) ==";  "$HERE/test_portability.sh"   || RC=1
echo; echo "== branding (📦 banner + h1) ==";            "$HERE/test_branding.sh"      || RC=1
echo; echo "== destinations (detection + --list-destinations) =="; "$HERE/test_destinations.sh" || RC=1
echo; echo "== discovery (repo auto-discovery walk) ==";    "$HERE/test_discovery.sh"    || RC=1
echo; echo "== repo list (list-file I/O + merge) ==";       "$HERE/test_repo_list.sh"    || RC=1
echo; [ $RC -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit $RC
