#!/bin/bash
# Prompts, menus, prefs and --reset-choices (plan Task 4). Terminal runs ask:
# the startup menu (remembered choices exist) BEFORE discovery; the mode prompt
# (review/automatic + remember? [y/N]) when new remote repos exist and no mode
# is remembered; the review menu (pre-ticked, toggle by number, a/n/Enter) in
# review mode; the per-repo no-remote menu (shows size, 1=copy 2=leave out).
# EOF at any prompt aborts like q. A non-terminal run NEVER prompts (alarm
# proof), parks no-remote repos as `?`, and --reset-choices exits 2 with a
# message. Prefs live in ~/.claude-migration-prefs as key=value; malformed
# values are treated as absent. Pty runs use script -q /dev/null with keys
# paced 1.5 s apart (flat input races the child — measured in test_destinations).
#
# Usage: test_prompts.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
mkrepo() {  # mkrepo <abs-path> [origin-url]
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "${2:-}" ]; then git -C "$d" remote add origin "$2" 2>/dev/null; fi
}
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
FAKE=""; OUT=""; PTYOUT="$HERE/.tmp-pty-prompts.out"
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  rm -rf "$STUB" "$PTYOUT"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT
fresh() {
  FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
  OUT=$(mktemp -d); rm -rf "$OUT"; mkdir -p "$OUT"
  LIST="$FAKE/.claude-migration-repos"; PREFS="$FAKE/.claude-migration-prefs"
}
menu_out() { tr -d '\r' < "$PTYOUT"; }
# run_pty <fake-home> <out> <keys...> — interactive pty run, keys paced 1.5 s
run_pty() {
  local h="$1" o="$2"; shift 2
  { sleep 1; for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done; } \
    | env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$h" PATH="$STUB:$SAVED_PATH" \
      script -q /dev/null /bin/bash "$ROOT/backup.sh" "$o" >"$PTYOUT" 2>&1
}
# run_plain <fake-home> <out> [args...] — non-terminal, alarm-guarded, stdin /dev/null
run_plain() {
  local h="$1" o="$2"; shift 2
  env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$h" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 45; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$o" "$@" </dev/null 2>&1
}

# 1. mode prompt: Enter = review -> remember? n -> review list shown -> accept
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2" "https://example.com/r2.git"
RC=0; run_pty "$FAKE" "$OUT" "" "n" "" || RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -q 'How should I record' \
   && menu_out | grep -q 'New repos with a remote' \
   && menu_out | grep -q '\[x\]' \
   && [ ! -e "$PREFS" ] \
   && grep -Fqx 'r1' "$LIST" && grep -Fqx 'r2' "$LIST"; then
  ok "mode prompt: Enter=review, review list pre-ticked, accept records, remember=n writes no prefs"
else
  bad "mode prompt" "RC=$RC prefs=$([ -e "$PREFS" ] && echo yes) list=$(tr '\n' '|' < "$LIST" 2>/dev/null) out=$(menu_out | tail -6 | tr '\n' '|')"
fi

# 2. mode prompt remember=y writes repo_mode=review to the prefs file
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
RC=0; run_pty "$FAKE" "$OUT" "" "y" "" || RC=$?
if [ "$RC" -eq 0 ] && grep -q '^repo_mode=review$' "$PREFS" 2>/dev/null; then
  ok "remember=y persists repo_mode=review"
else
  bad "remember=y" "RC=$RC prefs=$(cat "$PREFS" 2>/dev/null | tr '\n' '|')"
fi

# 3. automatic mode: bare lines, no review menu
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
RC=0; run_pty "$FAKE" "$OUT" "2" "n" || RC=$?
if [ "$RC" -eq 0 ] \
   && ! menu_out | grep -q 'New repos with a remote' \
   && grep -Fqx 'r1' "$LIST" \
   && [ ! -e "$PREFS" ]; then
  ok "automatic mode: bare line appended, no review menu, remember=n no prefs"
else
  bad "automatic mode" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 4. startup menu Enter carries on; remembered-in-use line names BOTH reset ways
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
printf 'repo_mode=auto\n' > "$PREFS"
RC=0; run_pty "$FAKE" "$OUT" "" || RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -q 'Remembered choices' \
   && ! menu_out | grep -q 'How should I record' \
   && grep -q 'using remembered choices' "$PTYOUT" \
   && grep -q -- '--reset-choices' "$PTYOUT" \
   && grep -q 'startup menu' "$PTYOUT" \
   && grep -Fqx 'r1' "$LIST"; then
  ok "startup menu: Enter carries on (no mode re-ask), in-use line names both reset ways"
else
  bad "startup menu carry-on" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null) out=$(menu_out | tail -6 | tr '\n' '|')"
fi

# 5. startup menu 2/c re-asks the mode (answer automatic -> bare line)
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
printf 'repo_mode=review\n' > "$PREFS"
RC=0; run_pty "$FAKE" "$OUT" "2" "2" "y" || RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -q 'How should I record' \
   && grep -Fqx 'r1' "$LIST" \
   && grep -q '^repo_mode=auto$' "$PREFS" 2>/dev/null; then
  ok "startup menu change: mode re-asked, automatic answer recorded in prefs"
else
  bad "startup menu change" "RC=$RC prefs=$(cat "$PREFS" 2>/dev/null | tr '\n' '|')"
fi

# 6. startup menu 3/r re-scan: an excluded remote repo is offered again (auto -> bare)
fresh
mkrepo "$FAKE/excl" "https://example.com/excl.git"
printf '!excl\n' > "$LIST"
printf 'repo_mode=auto\n' > "$PREFS"
RC=0; run_pty "$FAKE" "$OUT" "3" || RC=$?
if [ "$RC" -eq 0 ] \
   && grep -Fqx 'excl' "$LIST" \
   && ! grep -Fqx '!excl' "$LIST"; then
  ok "startup menu re-scan: excluded repo re-decided (auto adds bare, ! line gone)"
else
  bad "startup menu re-scan" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 7. startup menu q aborts with rc 1 and writes nothing
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
printf 'repo_mode=auto\n' > "$PREFS"
RC=0; run_pty "$FAKE" "$OUT" "q" || RC=$?
if [ "$RC" -eq 1 ] && [ ! -e "$LIST" ]; then
  ok "startup menu q: abort rc 1, no list file written"
else
  bad "startup menu abort" "RC=$RC list=$([ -e "$LIST" ] && echo yes)"
fi

# 8. per-repo no-remote menu: shows name + size; 1 = copy (whole tree)
fresh
mkrepo "$FAKE/local"
printf 'hello\n' > "$FAKE/local/README"
RC=0; run_pty "$FAKE" "$OUT" "1" || RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -q 'local' \
   && menu_out | grep -qi 'size' \
   && grep -Fqx '+local' "$LIST"; then
  ok "per-repo menu: name + size shown, 1=copy writes + line"
else
  bad "per-repo copy" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null) out=$(menu_out | tail -6 | tr '\n' '|')"
fi

# 9. per-repo menu 2 = leave out (!)
fresh
mkrepo "$FAKE/local"
RC=0; run_pty "$FAKE" "$OUT" "2" || RC=$?
if [ "$RC" -eq 0 ] && grep -Fqx '!local' "$LIST"; then
  ok "per-repo menu: 2=leave out writes ! line"
else
  bad "per-repo leave-out" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 10. review menu toggles: number toggles, n = none
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2" "https://example.com/r2.git"
RC=0; run_pty "$FAKE" "$OUT" "" "n" "2" "" || RC=$?
if [ "$RC" -eq 0 ] && grep -Fqx 'r1' "$LIST" && grep -Fqx '!r2' "$LIST"; then
  ok "review menu: toggle by number (r2 off), Enter accepts -> r1 recorded, r2 excluded"
else
  bad "review toggle" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2" "https://example.com/r2.git"
RC=0; run_pty "$FAKE" "$OUT" "" "n" "n" "" || RC=$?
if [ "$RC" -eq 0 ] && grep -Fqx '!r1' "$LIST" && grep -Fqx '!r2' "$LIST"; then
  ok "review menu: n ticks none -> both excluded"
else
  bad "review none" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 11. parked ? repo is asked on the next TERMINAL run (per-repo menu)
fresh
mkrepo "$FAKE/parked"
printf '?parked\n' > "$LIST"
RC=0; run_pty "$FAKE" "$OUT" "2" || RC=$?
if [ "$RC" -eq 0 ] && grep -Fqx '!parked' "$LIST" && ! grep -Fqx '?parked' "$LIST"; then
  ok "parked ? repo asked on terminal run, answer lands as ! line"
else
  bad "parked asked" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 12. non-terminal proofs: full run never prompts; reset flag exits 2
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/local"
out=$(run_plain "$FAKE" "$OUT"); RC=$?
if [ "$RC" -eq 0 ] \
   && ! printf '%s' "$out" | grep -q 'How should I record' \
   && ! printf '%s' "$out" | grep -q 'Remembered choices' \
   && grep -Fqx '?local' "$LIST" \
   && grep -Fqx 'r1' "$LIST"; then
  ok "non-terminal full run: rc 0, no prompts, ? parked for no-remote"
else
  bad "non-terminal run" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi
fresh
printf 'repo_mode=auto\n' > "$PREFS"
printf '!x\n' > "$LIST"
out=$(run_plain "$FAKE" "$OUT" --reset-choices); RC=$?
if [ "$RC" -eq 2 ] \
   && printf '%s' "$out" | grep -qi 'terminal' \
   && grep -q '^repo_mode=auto$' "$PREFS" \
   && grep -Fqx '!x' "$LIST"; then
  ok "--reset-choices non-terminal: rc 2 + message, prefs and list untouched"
else
  bad "reset non-terminal" "RC=$RC out=$(printf '%s' "$out" | head -2 | tr '\n' '|')"
fi
fresh
printf 'repo_mode=auto\n' > "$PREFS"
out=$(env MIGRATION_REPOS="r1" HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
      perl -e 'alarm 45; exec @ARGV' /bin/bash "$ROOT/backup.sh" --reset-choices "$OUT" </dev/null 2>&1); RC=$?
if [ "$RC" -eq 2 ] && grep -q '^repo_mode=auto$' "$PREFS"; then
  ok "--reset-choices + MIGRATION_REPOS: rc 2, prefs not touched"
else
  bad "reset + env" "RC=$RC prefs=$(cat "$PREFS" 2>/dev/null | tr '\n' '|')"
fi

# 13. --reset-choices (pty): repo_mode deleted, ! line re-asked (auto -> bare).
#     The flag goes in ARGV; keys: "" (startup menu carry-on), "2" (mode auto), "n".
fresh
mkrepo "$FAKE/x" "https://example.com/x.git"
printf '!x\n' > "$LIST"
printf 'repo_mode=auto\n' > "$PREFS"
{ sleep 1; for k in "" "2" "n"; do printf '%s\n' "$k"; sleep 1.5; done; } \
  | env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" --reset-choices "$OUT" >"$PTYOUT" 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && ! grep -q '^repo_mode=' "$PREFS" 2>/dev/null \
   && grep -Fqx 'x' "$LIST" \
   && ! grep -Fqx '!x' "$LIST"; then
  ok "--reset-choices: repo_mode deleted, ! repo re-offered and re-recorded"
else
  bad "reset pty" "RC=$RC prefs=$(cat "$PREFS" 2>/dev/null | tr '\n' '|') list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 14. --reset-choices --dry-run (pty): announces only, prefs + list unchanged
fresh
mkrepo "$FAKE/x" "https://example.com/x.git"
printf '!x\n' > "$LIST"
printf 'repo_mode=auto\n' > "$PREFS"
cp "$PREFS" "$FAKE/prefs.orig"; cp "$LIST" "$FAKE/list.orig"
( sleep 2 ) | env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" --reset-choices --dry-run >"$PTYOUT" 2>&1
if menu_out | grep -qi 'reset-choices' \
   && cmp -s "$PREFS" "$FAKE/prefs.orig" \
   && cmp -s "$LIST" "$FAKE/list.orig"; then
  ok "--reset-choices --dry-run: announces, prefs and list untouched"
else
  bad "reset dry-run" "out=$(menu_out | tail -4 | tr '\n' '|')"
fi

# 15. --help documents --reset-choices; malformed pref treated as absent
if "$ROOT/backup.sh" --help 2>&1 | grep -q -- '--reset-choices'; then
  ok "--help documents --reset-choices"
else
  bad "--help" "missing --reset-choices line"
fi
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
printf 'repo_mode=banana\njunkline\n' > "$PREFS"
out=$(run_plain "$FAKE" "$OUT"); RC=$?
if [ "$RC" -eq 0 ] && grep -Fqx 'r1' "$LIST"; then
  ok "malformed prefs (repo_mode=banana, junk): treated as absent, run succeeds"
else
  bad "malformed prefs" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

# 16. EOF at the mode prompt aborts like q (closed stdin mid-prompt, rc 1)
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
{ sleep 1; } | env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" "$OUT" >"$PTYOUT" 2>&1
if menu_out | grep -qi 'aborted'; then
  ok "EOF at a prompt aborts like q (aborted message)"
else
  bad "EOF abort" "out=$(menu_out | tail -4 | tr '\n' '|')"
fi

# 17. pty --dry-run with remembered review mode + a new remote repo: NEVER prompts
#     (design anti-goal) — no review menu banner, rc 0, nothing written
fresh
mkrepo "$FAKE/proj" "https://example.com/proj.git"
printf 'repo_mode=review\n' > "$PREFS"
printf '!other\n' > "$LIST"
{ sleep 3; } | env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" --dry-run "$OUT" >"$PTYOUT" 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && ! menu_out | grep -q 'New repos with a remote' \
   && ! menu_out | grep -q 'How should I record' \
   && ! menu_out | grep -q 'Remembered choices' \
   && menu_out | grep -q 'DRY RUN' \
   && grep -Fqx '!other' "$LIST" \
   && grep -q '^repo_mode=review$' "$PREFS"; then
  ok "pty --dry-run: no repo menu opens (review mode remembered), rc 0, files untouched"
else
  bad "pty dry-run no-prompt" "RC=$RC out=$(menu_out | grep -aE '📦|DRY|aborted' | head -3 | tr '\n' '|')"
fi

# 18. startup menu "change" (2/c) re-decides an EXCLUDED repo: filter drops the !
#     line, the repo comes back as new, auto mode re-records it bare
fresh
mkrepo "$FAKE/x" "https://example.com/x.git"
printf '!x\n' > "$LIST"
printf 'repo_mode=review\n' > "$PREFS"
RC=0; run_pty "$FAKE" "$OUT" "2" "2" "n" || RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -q 'Remembered choices' \
   && menu_out | grep -q 'How should I record' \
   && grep -Fqx 'x' "$LIST" \
   && ! grep -Fqx '!x' "$LIST"; then
  ok "startup menu change: mode re-asked AND excluded repo re-offered (bare, ! gone)"
else
  bad "change re-decides" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
