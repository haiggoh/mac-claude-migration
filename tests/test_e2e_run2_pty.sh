#!/bin/bash
# Focused regression test for the e2e run-2 pty flake (waypoint mcm-e2e-run-2-pty-using).
#
# Root cause (captured 2026-11-10, /tmp/pty-10.out; reproduced deterministically
# 2026-11-11, 5/5 with an immediately-closing feeder): the key feeder closed stdin at
# t=2.5s; when `script`'s stdin EOFs it forwards EOF into the pty, which consumes the
# queued '\n' — if backup.sh under load has not reached the startup-menu read yet, the
# read gets EOF -> ans="q" -> "backup aborted" -> no 'using remembered choices' line.
# (A suspected line-wrap shape was DISPROVEN by measurement: pty output is never
# wrapped by the line discipline, cols=40 leaves the line intact.)
#
# Controls proven here (driver = tests/lib/pty_drive.py, condition-based key send):
#   case 1  the menu answer survives a 4 s delayed startup (the old timed `script`
#           feeder went RED 5/5 on this shape under load — /tmp/mutA2-*.out)
#   case 2  watchdog pin: a child that never exits is killed at the deadline (rc 124),
#           so a hung pty can never stall the gate
#
# Usage: test_e2e_run2_pty.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx"; chmod +x "$STUB/pipx"
FAKE=""; OUT=""
cleanup() { [ -n "$FAKE" ] && rm -rf "$FAKE"; [ -n "$OUT" ] && rm -rf "$OUT"; rm -rf "$STUB"; HOME="$SAVED_HOME"; }
trap cleanup EXIT
mkrepo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
  printf 'content\n' > "$d/seed.txt"; git -C "$d" add seed.txt
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null; }

# pty_run <outfile> <timeout> <child-prefix...> -- runs backup.sh on a pty via
# tests/lib/pty_drive.py (key sent when the menu appears; master never closed early).
# Sets PTY_RC to the child's exit status.
pty_run() {
  local out="$1" tmo="$2"; shift 2
  env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    python3 "$HERE/lib/pty_drive.py" "$out" "$tmo" -- /bin/bash -c "$* exec /bin/bash '$ROOT/backup.sh' \"\$1\"" _ "$OUT"
  PTY_RC=$?
}
line_present() { tr -d '\r\n' < "$1" | grep -q 'using remembered choices'; }

# --- fixture: two repos, list seeded with a record and a copy line -------------------
FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
OUT=$(mktemp -d); rm -rf "$OUT"; mkdir -p "$OUT"
mkrepo "$FAKE/rem"; mkrepo "$FAKE/local"
printf 'rem\n+local\n' > "$FAKE/.claude-migration-repos"

# --- case 1: menu answer survives a 4 s delayed startup (old timed feeder RED 5/5) --
P1=$(mktemp)
pty_run "$P1" 90 'sleep 4;'
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
if line_present "$P1" && [ -n "$arch" ] && tar -tzf "$arch" 2>/dev/null | grep -q '^\./repo-copies/local\.tar\.gz$'; then
  ok "case 1: delayed startup, condition-based key -> remembered-choices line + copy tarball"
else
  bad "case 1" "rc=$PTY_RC line=$(line_present "$P1" && echo y || echo n) arch=$([ -n "$arch" ] && echo y || echo n) out=$(tr -d '\r' < "$P1" | tail -2 | tr '\n' '|')"
fi
rm -f "$OUT"/claude-migration-*.tar.gz

# --- case 2: watchdog pin — a hung child is killed at the deadline, gate can't stall -
P2=$(mktemp)
env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
  python3 "$HERE/lib/pty_drive.py" "$P2" 5 -- /bin/bash -c 'sleep 30'
WRC=$?
if [ "$WRC" -eq 124 ]; then
  ok "case 2: hung child killed at watchdog deadline (rc 124), no gate stall"
else
  bad "case 2" "rc=$WRC (want 124)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
