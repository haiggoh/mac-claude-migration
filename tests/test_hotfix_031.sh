#!/bin/bash
# v0.3.1 hotfix pins. A live run looked WEDGED (2026-11-24): step 6/6 packed
# 62 GB of cargo target/ dirs out of ~/.claude/backups for 27+ min with no
# output, and the interrupt left a 65 GB temp build (secrets) behind. Pins:
#   * build output (CACHEDIR.TAG dirs, cargo target/ with .rustc_info.json or
#     <profile>/.fingerprint) is excluded; a plain dir named target is kept
#   * progress helpers (bar, bytes) are exact; progress is OFF when stderr is
#     not a terminal, ON with MCM_PROGRESS=1, and a bogus MCM_PROGRESS exits 2
#   * an interrupted run removes its stage + partial archive (local) and the
#     whole mktemp build dir (cloud-only pick)
#   * unpushed commits warn ONCE per repository, not once per linked worktree
#   * batch no-remote menu: numbers pick repos, a/n/o are the actions
#   * ~/.claude/backups is asked about on a terminal run (size shown)
#   * shellcheck is clean on all three scripts
#
# Usage: test_hotfix_031.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
extract() { sed -n "/^$1() {/,/^}/p" "$ROOT/backup.sh"; }
warn() { printf '⚠ %s\n' "$*"; }
log()  { printf '▶ %s\n' "$*"; }
mkrepo() {  # mkrepo <abs-path> [origin-url]
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "${2:-}" ]; then git -C "$d" remote add origin "$2" 2>/dev/null; fi
}
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
SLOWSTUB=$(mktemp -d)   # brew that stalls step 5/6 so a run can be interrupted mid-way
printf '#!/bin/sh\nsleep 3\nexit 1\n' > "$SLOWSTUB/brew"; chmod +x "$SLOWSTUB/brew"
cp "$STUB/pipx" "$SLOWSTUB/pipx"
FAKE=""; OUT=""; PTYOUT="$HERE/.tmp-pty-hotfix.out"
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  rm -rf "$STUB" "$SLOWSTUB" "$PTYOUT"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT
fresh() {
  FAKE=$(mktemp -d); OUT=$(mktemp -d)
  LIST="$FAKE/.claude-migration-repos"; LOG="$OUT/../run-$$.log"
}
menu_out() { tr -d '\r' < "$PTYOUT"; }
run_plain() {  # run_plain [env assignments...] — non-terminal run into $OUT, output in $LOG, rc in RC
  env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES -u MCM_PROGRESS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" "$@" \
    perl -e 'alarm 90; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null >"$LOG" 2>&1
  RC=$?
}
run_pty() {  # run_pty <keys...> — interactive pty run into $OUT, keys paced 1.5 s
  { sleep 1; for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done; } \
    | env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES -u MCM_PROGRESS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
      script -q /dev/null /bin/bash "$ROOT/backup.sh" "$OUT" >"$PTYOUT" 2>&1
}
archive_list() { local a; for a in "$OUT"/claude-migration-*.tar.gz; do tar tzf "$a" 2>/dev/null; return; done; }

# --- 1. progress helpers: exact bar + percent, bytes ------------------------------
eval "$(extract _progress_bar)"
eval "$(extract _human_bytes)"
b0="$(_progress_bar 0 10 10)"; b5="$(_progress_bar 5 10 10)"; b10="$(_progress_bar 10 10 10)"
bz="$(_progress_bar 3 0 10)"; bo="$(_progress_bar 15 10 10)"
if [ "$b0" = "[----------]   0%" ] && [ "$b5" = "[#####-----]  50%" ] \
   && [ "$b10" = "[##########] 100%" ] && [ "$bz" = "[----------]   0%" ] \
   && [ "$bo" = "[##########] 100%" ]; then
  ok "_progress_bar: 0/50/100%, total 0 and overshoot clamp"
else
  bad "_progress_bar" "0=[$b0] 5=[$b5] 10=[$b10] z=[$bz] o=[$bo]"
fi
h1="$(_human_bytes 512)"; h2="$(_human_bytes 1536)"; h3="$(_human_bytes 5242880)"; h4="$(_human_bytes 16106127360)"
if [ "$h1" = "512 B" ] && [ "$h2" = "1.5 KB" ] && [ "$h3" = "5.0 MB" ] && [ "$h4" = "15.0 GB" ]; then
  ok "_human_bytes: B / KB / MB / GB"
else
  bad "_human_bytes" "[$h1] [$h2] [$h3] [$h4]"
fi

# --- 2. build output excluded, real content kept -----------------------------------
fresh
W="$FAKE/.claude/backups/worktrees/app-1"
mkdir -p "$W/src-tauri/target/debug/.fingerprint" "$W/src-tauri/src"
printf '{}' > "$W/src-tauri/target/.rustc_info.json"
printf 'objbytes' > "$W/src-tauri/target/debug/big.rlib"
printf 'fn main(){}' > "$W/src-tauri/src/main.rs"
W2="$FAKE/.claude/backups/worktrees/app-2/target"       # untagged cargo target (no .rustc_info)
mkdir -p "$W2/release/.fingerprint"; printf 'x' > "$W2/release/app"
mkdir -p "$FAKE/.claude/cachey"; printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$FAKE/.claude/cachey/CACHEDIR.TAG"
printf 'junk' > "$FAKE/.claude/cachey/blob"
mkdir -p "$FAKE/.claude/notes/target"; printf 'keep me' > "$FAKE/.claude/notes/target/plan.md"   # NOT build output
run_plain
L="$(archive_list)"
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$L" | grep -q 'app-1/src-tauri/src/main.rs$' \
   && ! printf '%s\n' "$L" | grep -q 'big.rlib' \
   && ! printf '%s\n' "$L" | grep -q 'app-2/target/release/app' \
   && ! printf '%s\n' "$L" | grep -q 'cachey/blob' \
   && printf '%s\n' "$L" | grep -q 'notes/target/plan.md$'; then
  ok "build output: cargo target (tagged + untagged) and CACHEDIR.TAG dirs excluded; plain target/ kept"
else
  bad "build-output excludes" "RC=$RC list=$(printf '%s\n' "$L" | grep -E 'rlib|app-2|cachey|plan.md|main.rs' | tr '\n' '|') log=$(tail -4 "$LOG" | tr '\n' '|')"
fi
if grep -q 'build output' "$LOG"; then
  ok "build output: the run says how many build-output dirs it skipped"
else
  bad "build-output log line" "log=$(grep -n 'build' "$LOG" | head -3 | tr '\n' '|')"
fi

# --- 3. progress off when not a terminal; forced on; bogus value fails loudly ------
if ! LC_ALL=C grep -q $'\r' "$LOG" && ! grep -q '%' "$LOG"; then
  ok "progress: no \\r / percent lines in a piped (non-terminal) log"
else
  bad "progress off when piped" "found progress chrome in the piped log"
fi
fresh; mkdir -p "$FAKE/.claude"; printf 'x' > "$FAKE/.claude/settings.json"
run_plain MCM_PROGRESS=1
if [ "$RC" -eq 0 ] && grep -q 'packing.*%' "$LOG"; then
  ok "progress: MCM_PROGRESS=1 forces the ticker (pack shows a percent)"
else
  bad "MCM_PROGRESS=1" "RC=$RC log=$(tr '\r' '\n' < "$LOG" | grep -i pack | tail -3 | tr '\n' '|')"
fi
fresh; mkdir -p "$FAKE/.claude"; printf 'x' > "$FAKE/.claude/settings.json"
run_plain MCM_PROGRESS=maybe
if [ "$RC" -eq 2 ] && grep -q 'MCM_PROGRESS' "$LOG" && ! ls "$OUT"/claude-migration-* >/dev/null 2>&1 \
   && ! ls -d "$OUT"/stage-* >/dev/null 2>&1; then
  ok "progress: an invalid MCM_PROGRESS exits 2 naming it, before any work"
else
  bad "MCM_PROGRESS invalid" "RC=$RC log=$(head -3 "$LOG" | tr '\n' '|')"
fi

# --- 4. interrupt cleanup -----------------------------------------------------------
fresh; mkdir -p "$FAKE/.claude"; printf 'x' > "$FAKE/.claude/settings.json"
env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES -u MCM_PROGRESS HOME="$FAKE" PATH="$SLOWSTUB:$SAVED_PATH" \
  /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null >"$LOG" 2>&1 &
BPID=$!
i=0; while [ "$i" -lt 100 ] && ! grep -q '5/6' "$LOG" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
staged=0; ls -d "$OUT"/stage-* >/dev/null 2>&1 && staged=1
kill -TERM "$BPID" 2>/dev/null; wait "$BPID"; RC=$?
if [ "$staged" -eq 1 ] && [ "$RC" -ne 0 ] && ! ls -d "$OUT"/stage-* >/dev/null 2>&1 \
   && ! ls "$OUT"/claude-migration-* >/dev/null 2>&1; then
  ok "interrupt (local dest): stage and partial archive removed, rc non-zero"
else
  bad "interrupt local" "staged=$staged RC=$RC left=$(find "$OUT" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
fi
# cloud-only pick: the whole mktemp build dir goes
fresh; mkdir -p "$FAKE/.claude" "$FAKE/Library/CloudStorage/FakeDrive"; printf 'x' > "$FAKE/.claude/settings.json"
PT="$OUT/tmp"; mkdir -p "$PT"
{ sleep 1; printf 'a\n'; sleep 30; } \
  | env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES -u MCM_PROGRESS HOME="$FAKE" TMPDIR="$PT" PATH="$SLOWSTUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" >"$PTYOUT" 2>&1 &
SPID=$!
i=0; while [ "$i" -lt 150 ] && ! tr -d '\r' < "$PTYOUT" 2>/dev/null | grep -q '5/6'; do sleep 0.1; i=$((i+1)); done
built=0; ls -d "$PT"/mcm-build.* >/dev/null 2>&1 && built=1
for p in $(pgrep -f "$ROOT/backup.sh"); do kill -TERM "$p" 2>/dev/null; done   # this test's run only (worktree path)
i=0; while [ "$i" -lt 100 ] && pgrep -f "$ROOT/backup.sh" >/dev/null; do sleep 0.1; i=$((i+1)); done
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
if [ "$built" -eq 1 ] && ! ls -d "$PT"/mcm-build.* >/dev/null 2>&1; then
  ok "interrupt (cloud-only pick): the temp build dir is removed"
else
  bad "interrupt cloud" "built=$built left=$(find "$PT" -mindepth 1 -maxdepth 1 | tr '\n' ' ') out=$(menu_out | tail -3 | tr '\n' '|')"
fi

# --- 5. unpushed warned once per repository ----------------------------------------
fresh
BARE="$OUT/../bare-$$.git"; git init -q --bare "$BARE"
mkrepo "$FAKE/proj" "$BARE"
git -C "$FAKE/proj" push -q origin main 2>/dev/null
git -C "$FAKE/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local-only
git -C "$FAKE/proj" worktree add -q "$FAKE/wt/a" -b wa 2>/dev/null
git -C "$FAKE/proj" worktree add -q "$FAKE/wt/b" -b wb 2>/dev/null
run_plain
n="$(grep -c 'UNPUSHED' "$LOG")"
rm -rf "$BARE"
if [ "$RC" -eq 0 ] && [ "$n" -eq 1 ]; then
  ok "unpushed: one warning for a repo with two linked worktrees"
else
  bad "unpushed dedupe" "RC=$RC count=$n lines=$(grep 'UNPUSHED' "$LOG" | tr '\n' '|')"
fi

# --- 6. batch menu: numbers pick repos ----------------------------------------------
fresh
mkrepo "$FAKE/l1"; mkrepo "$FAKE/l2"; mkrepo "$FAKE/l3"
RC=0; run_pty "2" || RC=$?
two="$(menu_out | sed -n 's/^   2) \([^ ]*\)  (.*without gitignored.*/\1/p' | head -1)"
plus="$(grep -c '^+' "$LIST" 2>/dev/null)"; bang="$(grep -c '^!' "$LIST" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ -n "$two" ] && grep -Fqx "+$two" "$LIST" && [ "$plus" -eq 1 ] && [ "$bang" -eq 2 ] \
   && menu_out | grep -q 'a) copy ALL'; then
  ok "batch menu: '2' copies just repo #2 ($two), leaves the rest out; actions are letters"
else
  bad "batch pick" "RC=$RC two=$two list=$(tr '\n' '|' < "$LIST" 2>/dev/null) out=$(menu_out | grep -E '^ +[0-9a-z]\)' | tr '\n' '|')"
fi
fresh
mkrepo "$FAKE/l1"; mkrepo "$FAKE/l2"
RC=0; run_pty "1,9" "1 2" || RC=$?
if [ "$RC" -eq 0 ] && menu_out | grep -q 'Unrecognized: 1,9' \
   && ! menu_out | grep -q 'Unrecognized: 1 2' \
   && grep -Fqx '+l1' "$LIST" && grep -Fqx '+l2' "$LIST"; then
  ok "batch menu: an out-of-range number re-asks; '1 2' then copies both"
else
  bad "batch pick range" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# --- 7. ~/.claude/backups asked about on a terminal ---------------------------------
fresh; mkdir -p "$FAKE/.claude/backups/snap"; printf 'old' > "$FAKE/.claude/backups/snap/f.md"
printf 'x' > "$FAKE/.claude/settings.json"
RC=0; run_pty "2" || RC=$?
L="$(archive_list)"
if [ "$RC" -eq 0 ] && menu_out | grep -q '\.claude/backups' \
   && ! printf '%s\n' "$L" | grep -q 'backups/snap/f.md' && printf '%s\n' "$L" | grep -q 'settings.json'; then
  ok "backups prompt: 2 = leave ~/.claude/backups out of the archive"
else
  bad "backups leave-out" "RC=$RC out=$(menu_out | grep -i backups | tr '\n' '|')"
fi
fresh; mkdir -p "$FAKE/.claude/backups/snap"; printf 'old' > "$FAKE/.claude/backups/snap/f.md"
RC=0; run_pty "" || RC=$?
if [ "$RC" -eq 0 ] && archive_list | grep -q 'backups/snap/f.md'; then
  ok "backups prompt: Enter = include"
else
  bad "backups include" "RC=$RC"
fi

# --- 8. shellcheck clean ------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck "$ROOT/backup.sh" "$ROOT/restore.sh" "$ROOT/mac-claude-migration.sh" 2>&1)"
  if [ -z "$sc" ]; then ok "shellcheck: 0 findings on backup.sh, restore.sh, mac-claude-migration.sh"
  else bad "shellcheck" "$(printf '%s\n' "$sc" | grep -E '^In |SC[0-9]+' | head -6 | tr '\n' '|')"; fi
else
  bad "shellcheck" "not installed — brew install shellcheck (a missing linter is not a pass)"
fi

echo; echo "hotfix 0.3.1: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
