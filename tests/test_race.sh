#!/bin/bash
# Race-tolerance pins (v0.3.0 plan Tasks 1-2). On a LIVE machine files vanish
# mid-backup — sessions rewrite ~/.claude, the waypoints-backups ring rotates,
# repos are edited concurrently (measured 2026-11-23: rsync exit 23 "open (2)
# ... No such file or directory" and tar "Cannot stat" both killed the whole
# run under set -e). Contract: vanished files are warned and skipped, NEVER
# fatal; any other rsync/tar error stays fatal; missing listed repos stay
# warn-only. Deterministic pins extract the classifier + wrappers from
# backup.sh by function name (same sed range as test_discovery.sh) and drive
# them with crafted logs and real rsync/tar runs; e2e cases run the whole
# backup against a fake HOME while a background deleter vanishes source files.
#
# Usage: test_race.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
extract() { sed -n "/^$1() {/,/^}/p" "$ROOT/backup.sh"; }
# stubs for the extracted helpers (warn is defined later in backup.sh itself)
warn() { printf '⚠ %s\n' "$*"; }
log()  { printf '▶ %s\n' "$*"; }
eval "$(extract _vanish_log_count)"
eval "$(extract _rsync_tolerant)"
eval "$(extract _tar_tolerant)"
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
FAKE=""; OUT=""; LOG=""
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  [ -n "$LOG" ] && rm -f "$LOG"
  rm -rf "$STUB"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT
fresh() { FAKE=$(mktemp -d); OUT=$(mktemp -d); LOG="$OUT/run.log"; }
mkrepo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  [ -n "${2:-}" ] && git -C "$d" remote add origin "$2" 2>/dev/null
}
run_backup() {  # non-terminal, alarm-guarded; output to $LOG, rc in $RC
  env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null >"$LOG" 2>&1
  RC=$?
}

# --- classifier unit pins -----------------------------------------------------
# 1. vanished-only log -> rc 0, count printed on stdout
L=$(mktemp)
printf 'rsync(1): error: a.json: open (2) in /h: No such file or directory\nrsync: b vanished\ntar: Error exit delayed from previous errors.\nskipping non-regular file "c"\n' > "$L"
n="$(_vanish_log_count "$L" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$n" = "4" ]; then
  ok "classifier: vanished-only log (incl. tar delayed-exit) -> rc 0, count 4"
else
  bad "classifier vanished-only" "rc=$rc n=$n"
fi
# 2. a real error line -> rc 1; the classifier itself stays quiet (the caller
#    prints the log once on the fatal path, so no double reporting)
printf 'rsync(1): error: a.json: open (2) in /h: Permission denied\n' > "$L"
out="$(_vanish_log_count "$L" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
  ok "classifier: Permission denied -> rc 1, classifier quiet (caller prints log)"
else
  bad "classifier real-error" "rc=$rc stderr=$out"
fi
rm -f "$L"

# --- _rsync_tolerant unit pins ------------------------------------------------
# 3. vanished source (rsync link_stat No such file, exit 23) -> tolerated rc 0 AND warned
fresh
out3="$(_rsync_tolerant -a "$FAKE/nope-vanished" "$OUT/dest/" 2>&1)"; rc3=$?
if [ "$rc3" -eq 0 ] && printf '%s' "$out3" | grep -q 'vanished'; then
  ok "_rsync_tolerant: vanished source arg (exit 23 class) -> rc 0 + warn mentions vanished"
else
  bad "_rsync_tolerant vanished" "rc=$rc3 out=$out3"
fi
# 4. a real rsync error (unknown option) -> fatal rc 1
if _rsync_tolerant --definitely-not-an-rsync-flag 2>/dev/null; then
  bad "_rsync_tolerant real-error" "rc=0, expected fatal"
else
  ok "_rsync_tolerant: real error (bad flag) -> rc 1 fatal"
fi

# --- _tar_tolerant unit pins --------------------------------------------------
# 5. filelist with one vanished + one real entry -> rc 0, tar holds the real file
fresh
mkdir -p "$FAKE/repo"; printf 'data\n' > "$FAKE/repo/real.txt"
printf 'real.txt\nvanished.txt\n' > "$FAKE/list"
out5="$( cd "$FAKE/repo" && _tar_tolerant "$OUT/t.tar.gz" "$FAKE/list" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && tar -tzf "$OUT/t.tar.gz" 2>/dev/null | grep -qx 'real.txt' \
   && ! tar -tzf "$OUT/t.tar.gz" 2>/dev/null | grep -q 'vanished.txt' \
   && printf '%s' "$out5" | grep -q 'vanished before tar'; then
  ok "_tar_tolerant: vanished filelist entry dropped + warned, real file packed, rc 0"
else
  bad "_tar_tolerant vanished entry" "rc=$rc out=$out5 contents=$(tar -tzf "$OUT/t.tar.gz" 2>/dev/null | tr '\n' '|')"
fi
# 6. unreadable real file -> tar Cannot open Permission denied -> fatal rc 1
fresh
mkdir -p "$FAKE/repo"; printf 'secret\n' > "$FAKE/repo/locked.txt"; chmod 000 "$FAKE/repo/locked.txt"
printf 'locked.txt\n' > "$FAKE/list"
( cd "$FAKE/repo" && _tar_tolerant "$OUT/t2.tar.gz" "$FAKE/list" 2>/dev/null ); rc=$?
chmod 644 "$FAKE/repo/locked.txt"
if [ "$rc" -eq 1 ]; then
  ok "_tar_tolerant: unreadable file (Cannot open: Permission denied) -> rc 1 fatal"
else
  bad "_tar_tolerant real-error" "rc=$rc, expected 1"
fi
# 7. all filelist entries vanished -> rc 0, no tar written
fresh
mkdir -p "$FAKE/repo"
printf 'gone1\ngone2\n' > "$FAKE/list"
out7="$( cd "$FAKE/repo" && _tar_tolerant "$OUT/t3.tar.gz" "$FAKE/list" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$OUT/t3.tar.gz" ] && printf '%s' "$out7" | grep -q 'every listed file vanished'; then
  ok "_tar_tolerant: all entries vanished -> rc 0, no empty tar written, warned"
else
  bad "_tar_tolerant all-vanished" "rc=$rc out=$out7 tar=$([ -e "$OUT/t3.tar.gz" ] && echo yes)"
fi

# --- e2e pins -----------------------------------------------------------------
# 8. full backup while .claude files vanish mid-run -> rc 0, archive built
fresh
mkdir -p "$FAKE/.claude/race"
i=0; while [ "$i" -lt 1200 ]; do printf 'x%s\n' "$i" > "$FAKE/.claude/race/f$i"; i=$((i+1)); done
printf 'big\n' > "$FAKE/.claude/bigfile"
( env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null >"$LOG" 2>&1; echo "RC:$?" >> "$LOG" ) &
BGPID=$!
i=0
while [ "$i" -lt 400 ]; do
  if [ -n "$(find "$OUT"/stage-*/home -type f 2>/dev/null | head -1)" ]; then break; fi
  sleep 0.05; i=$((i+1))
done
rm -rf "$FAKE/.claude/race"
wait "$BGPID"
rc="$(sed -n 's/^RC://p' "$LOG")"
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
# The race itself is timing-dependent (the RED proof of it firing is the pre-fix
# run: rc 23 in /tmp/mcm-prompts-red-era logs); here we pin "not fatal + archive".
# The warn TEXT is pinned deterministically by unit cases 3/5/7 above.
if [ "$rc" = "0" ] && [ -n "$arch" ]; then
  ok "e2e: .claude files vanished mid-rsync -> run completes rc 0, archive built"
else
  bad "e2e rsync race" "rc=$rc arch=${arch:+yes} log=$(tail -3 "$LOG" | tr '\n' '|')"
fi

# 9. a REAL rsync error (unreadable file) stays fatal end-to-end
fresh
mkdir -p "$FAKE/.claude"; printf 'secret\n' > "$FAKE/.claude/locked"; chmod 000 "$FAKE/.claude/locked"
run_backup
chmod 644 "$FAKE/.claude/locked"
if [ "$RC" -ne 0 ] && grep -q 'Permission denied' "$LOG"; then
  ok "e2e: unreadable .claude file -> Permission denied, run exits non-zero (fatal preserved)"
else
  bad "e2e fatal" "RC=$RC log=$(tail -3 "$LOG" | tr '\n' '|')"
fi

# 10. missing listed repos (bare + '+') -> warn only, rc 0, no repos.tsv row
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
printf 'gone\n+gone\n' > "$FAKE/.claude-migration-repos"
run_backup
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
tsv=""; [ -n "$arch" ] && tsv="$(tar -xzOf "$arch" ./repos.tsv 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ -n "$arch" ] \
   && grep -Fq 'listed repo missing: gone' "$LOG" \
   && printf '%s' "$tsv" | grep -q '^r1	' \
   && ! printf '%s' "$tsv" | grep -q 'gone'; then
  ok "e2e: missing listed repos (bare + '+') -> warned, rc 0, not in repos.tsv"
else
  bad "e2e missing repos" "RC=$RC tsv=$(printf '%s' "$tsv" | tr '\n' '|') log=$(grep -a 'missing\|repos:' "$LOG" | tr '\n' '|')"
fi

# 11. tar race e2e: repo files vanish between filelist and tar -> rc 0, archive built
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkdir -p "$FAKE/r1/race"
i=0; while [ "$i" -lt 800 ]; do printf 'y%s\n' "$i" > "$FAKE/r1/race/g$i"; i=$((i+1)); done
head -c 20000000 /dev/zero > "$FAKE/r1/big.bin" 2>/dev/null || dd if=/dev/zero of="$FAKE/r1/big.bin" bs=1m count=20 2>/dev/null
( env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null >"$LOG" 2>&1; echo "RC:$?" >> "$LOG" ) &
BGPID=$!
i=0
while [ "$i" -lt 400 ]; do
  if [ -n "$(find "$OUT"/stage-*/repo-overlays -name '*.filelist' 2>/dev/null | head -1)" ]; then break; fi
  sleep 0.05; i=$((i+1))
done
rm -rf "$FAKE/r1/race"
wait "$BGPID"
rc="$(sed -n 's/^RC://p' "$LOG")"
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
if [ "$rc" = "0" ] && [ -n "$arch" ]; then
  ok "e2e: repo files vanished mid-tar -> run completes rc 0, archive built"
else
  bad "e2e tar race" "rc=$rc arch=${arch:+yes} log=$(tail -3 "$LOG" | tr '\n' '|')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
