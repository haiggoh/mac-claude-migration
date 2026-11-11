#!/bin/bash
# Tests for the mac-claude-migration front-door wrapper (mac-claude-migration.sh).
# Delivery-level: runs the real script (and the real backup.sh/restore.sh behind it),
# pty cases via tests/lib/pty_drive.py. Version strings are derived from VERSION,
# never hardcoded.
# Usage: test_entrypoint.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
WRAP="$ROOT/mac-claude-migration.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
[ -x "$WRAP" ] || { echo "missing $WRAP" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
VER=$(tr -d '[:space:]' < "$ROOT/VERSION")

# 1. --help: exit 0, overview on stdout naming both real commands and the version
out=$(/bin/bash "$WRAP" --help 2>/dev/null); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "mac-claude-migration $VER" \
   && printf '%s' "$out" | grep -q 'mac-claude-backup' && printf '%s' "$out" | grep -q 'mac-claude-restore'; then
  ok "--help: overview with version $VER naming both commands, exit 0"
else
  bad "--help" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# 2. bare non-terminal: exit 2, overview on stderr, nothing on stdout
out=$(/bin/bash "$WRAP" </dev/null 2>/tmp/entry-bare.err); rc=$?
if [ $rc -eq 2 ] && [ -z "$out" ] && grep -q 'mac-claude-backup' /tmp/entry-bare.err; then
  ok "bare non-terminal: exit 2, overview on stderr only (never prompts)"
else
  bad "bare-nonterminal" "rc=$rc stdout='$out' stderr=$(head -1 /tmp/entry-bare.err 2>/dev/null)"
fi

# 3. unknown command: exit 2, names the bad command
err=$(/bin/bash "$WRAP" bogus </dev/null 2>&1); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$err" | grep -q 'unknown command: bogus'; then
  ok "unknown command: exit 2 with message"
else
  bad "unknown-cmd" "rc=$rc err=$(printf '%s' "$err" | head -1)"
fi

# 4./5. pass-through reaches the REAL scripts: first --help lines must match exactly
b1=$(/bin/bash "$WRAP" backup --help 2>&1 | head -1); b2=$(/bin/bash "$ROOT/backup.sh" --help 2>&1 | head -1)
r1=$(/bin/bash "$WRAP" restore --help 2>&1 | head -1); r2=$(/bin/bash "$ROOT/restore.sh" --help 2>&1 | head -1)
if [ "$b1" = "$b2" ] && [ -n "$b1" ] && [ "$r1" = "$r2" ] && [ -n "$r1" ]; then
  ok "backup|restore subcommands pass straight through to the real scripts"
else
  bad "passthrough" "backup: '$b1' vs '$b2' | restore: '$r1' vs '$r2'"
fi

# 6. pty menu: chrome appears, q quits with exit 0
P=$(mktemp)
python3 "$HERE/lib/pty_drive.py" "$P" 30 --when 'quit' --send 'q\n' -- /bin/bash "$WRAP" </dev/null >/dev/null 2>&1
mrc=$?
if [ $mrc -eq 0 ] && tr -d '\r' < "$P" | grep -q 'mac-claude-backup' && tr -d '\r' < "$P" | grep -q 'q) quit'; then
  ok "pty menu: both entries shown, q quits exit 0"
else
  bad "pty-menu-q" "rc=$mrc out=$(tr -d '\r' < "$P" | tr '\n' '|' | head -c 200)"
fi

# 7. pty menu dispatch: choosing 1 execs the real backup.sh (its runtime banner appears)
P=$(mktemp)
python3 "$HERE/lib/pty_drive.py" "$P" 20 --when 'mac-claude-restore' --send '1\n' -- /bin/bash "$WRAP" </dev/null >/dev/null 2>&1
if tr -d '\r' < "$P" | grep -q 'Mac Claude Migration'; then
  ok "pty menu choice 1 reaches backup.sh (runtime banner in transcript)"
else
  bad "pty-menu-dispatch" "out=$(tr -d '\r' < "$P" | tr '\n' '|' | head -c 200)"
fi
rm -f "$P" /tmp/entry-bare.err

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
