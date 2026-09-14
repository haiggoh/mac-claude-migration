#!/bin/bash
# Verify both scripts parse arguments BEFORE doing work, and never run on a probe.
#
# The bug this locks down was real: `restore.sh --help` was read as an archive
# FILENAME (printed "archive not found: --help", exit 0), and `backup.sh --help`
# ignored the flag and started the backup. A probe must never become an execution.
#
# Usage: test_cli_contract.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

for s in backup.sh restore.sh; do
  S="$ROOT/$s"

  # --help must print usage, exit 0, and mention the script
  if out=$("$S" --help 2>&1) && printf '%s' "$out" | grep -q "$s"; then
    ok "$s --help prints its own usage"
  else bad "$s --help" "did not print usage naming the script"; fi

  # --help must NOT do work: no output dir, no staging, no archive
  SENTINEL=$(mktemp -d); rm -rf "$SENTINEL"
  HOME_BAK=$HOME
  if out=$(HOME="$SENTINEL" "$S" --help 2>&1); then
    if [ -e "$SENTINEL" ]; then bad "$s --help" "created files under a fake HOME"; else ok "$s --help writes nothing"; fi
  else bad "$s --help" "exited non-zero"; fi
  HOME=$HOME_BAK

  # An unknown flag must be REJECTED BY THE PARSER -- not merely fail somewhere
  # downstream. The pre-fix backup.sh "failed" here only because mkdir choked on
  # the stray flag, which is an accident, not a contract. So require the script's
  # OWN diagnostic and that it wrote nothing.
  SENT2=$(mktemp -d); rm -rf "$SENT2"
  out=$(HOME="$SENT2" "$S" --definitely-not-a-flag 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then bad "$s unknown flag" "exited 0"
  elif ! printf '%s' "$out" | grep -q 'unknown option'; then
    bad "$s unknown flag" "failed downstream, not in the parser: ${out%%$'\n'*}"
  elif [ -e "$SENT2" ]; then bad "$s unknown flag" "did work before rejecting"
  else ok "$s parser rejects an unknown flag"; fi
  rm -rf "$SENT2"

  # help must be REAL, not a grep-able string: run it, don't match source
  if [ "$("$S" --help 2>&1 | wc -l)" -gt 3 ]; then ok "$s help has substance"
  else bad "$s help" "suspiciously short"; fi
done

# backup --dry-run must report without writing
SENT=$(mktemp -d); rm -rf "$SENT"
if out=$(HOME="$SENT" "$ROOT/backup.sh" --dry-run 2>&1); then
  if printf '%s' "$out" | grep -q 'DRY RUN'; then ok "backup.sh --dry-run announces itself"
  else bad "backup.sh --dry-run" "no DRY RUN banner"; fi
  if [ -e "$SENT" ]; then bad "backup.sh --dry-run" "wrote under a fake HOME"; else ok "backup.sh --dry-run writes nothing"; fi
else bad "backup.sh --dry-run" "exited non-zero"; fi

# restore.sh argument arity
if "$ROOT/restore.sh" >/dev/null 2>&1; then bad "restore.sh no args" "exited 0"; else ok "restore.sh requires an archive"; fi
if "$ROOT/restore.sh" a b >/dev/null 2>&1; then bad "restore.sh two args" "exited 0"; else ok "restore.sh rejects two archives"; fi

# both must be syntactically valid under bash 3.2 (the /bin/bash on macOS)
for s in backup.sh restore.sh; do
  if /bin/bash -n "$ROOT/$s" 2>/dev/null; then ok "$s parses under /bin/bash (3.2)"
  else bad "$s" "syntax error under bash 3.2"; fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
