#!/bin/bash
# Destination detection for the destination-selection menu (plan Task 1):
# `backup.sh --list-destinations` prints one "path<TAB>label" line per candidate,
# the default output dir FIRST, then every existing child of ~/Library/CloudStorage/,
# then the legacy dirs (~/Dropbox, ~/OneDrive), then iCloud Drive. Existing
# directories only, deduped by RESOLVED path (a CloudStorage root that is ~/Dropbox
# via a symlink is listed once), space-named roots intact, non-directory junk
# skipped. Every case runs against a fake HOME (mktemp -d), so detection is hermetic.
#
# Task 2 adds the interactive destination menu, TTY-gated: it opens only when no
# positional OUT was given AND both stdin and stdout are terminals. Its cases run
# through a pty (`script -q /dev/null`) with a fake HOME and PACED keystrokes --
# flat piped input races the child (the first read can hit EOF before the bytes
# land, measured), so keys are sent 1.5s apart. --dry-run keeps every case cheap.
#
# Usage: test_destinations.sh [--help]
set -u
export LC_ALL=C   # pin glob collation: the detection order must be deterministic
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

OUT=""; RC=0
run_list() {  # run_list <fake-home>: sets OUT (stdout+stderr) and RC
  OUT=$(HOME="$1" "$ROOT/backup.sh" --list-destinations 2>&1); RC=$?
}
DEFAULT_LABEL='Default — this is where the archive is built'
line() { printf '%s\t%s' "$1" "$2"; }        # one expected line, no trailing newline
show() { printf '%s' "$1" | tr '\t' '>'; }   # tabs made visible in failure messages
FAKE=""
trap '[ -n "$FAKE" ] && rm -rf "$FAKE"; :' EXIT

# 1. modern CloudStorage roots + legacy Dropbox + OneDrive + iCloud: the 5 detected dirs
#    plus the default, default FIRST, labels exact
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/OneDrive-SomeCompanyGmbH" \
         "$FAKE/Library/CloudStorage/GoogleDrive-xyz" \
         "$FAKE/Dropbox" "$FAKE/OneDrive" \
         "$FAKE/Library/Mobile Documents/com~apple~CloudDocs"
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")
$(line "$FAKE/Library/CloudStorage/GoogleDrive-xyz" 'GoogleDrive-xyz')
$(line "$FAKE/Library/CloudStorage/OneDrive-SomeCompanyGmbH" 'OneDrive-SomeCompanyGmbH')
$(line "$FAKE/Dropbox" 'Dropbox')
$(line "$FAKE/OneDrive" 'OneDrive')
$(line "$FAKE/Library/Mobile Documents/com~apple~CloudDocs" 'iCloud Drive')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "modern roots + legacy + iCloud: 5 detected + default first, exact labels"
else
  bad "modern roots + legacy + iCloud" "rc=$RC got: $(show "$OUT")"
fi
rm -rf "$FAKE"

# 2. a CloudStorage root whose name contains a space: present, path intact on one line
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/GoogleDrive-1 My Drive"
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")
$(line "$FAKE/Library/CloudStorage/GoogleDrive-1 My Drive" 'GoogleDrive-1 My Drive')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "space-named root: path intact on one line"
else
  bad "space-named root" "rc=$RC got: $(show "$OUT")"
fi
rm -rf "$FAKE"

# 3. missing CloudStorage + no legacy dirs: exactly 1 line (the default)
FAKE=$(mktemp -d)
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "missing CloudStorage + no legacy dirs: exactly 1 line (the default)"
else
  bad "missing everything" "rc=$RC got: $(show "$OUT")"
fi
if [ -z "$(find "$FAKE" -mindepth 1 -maxdepth 1)" ]; then
  ok "probe writes nothing under HOME (default dir not pre-created)"
else
  bad "probe writes nothing" "created: $(find "$FAKE" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
fi
rm -rf "$FAKE"

# 4. non-directory junk AND a broken symlink inside CloudStorage: skipped
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/RealRoot"
printf 'not a directory\n' > "$FAKE/Library/CloudStorage/notes.txt"
ln -s /nonexistent-target-xyz "$FAKE/Library/CloudStorage/Dead"
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")
$(line "$FAKE/Library/CloudStorage/RealRoot" 'RealRoot')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "non-directory junk + broken symlink inside CloudStorage: skipped"
else
  bad "non-directory junk skipped" "rc=$RC got: $(show "$OUT")"
fi
rm -rf "$FAKE"

# 5. a CloudStorage root that IS ~/Dropbox via a symlink: ONE entry (dedupe by
#    resolved path — the two spellings differ, so string equality would not catch it)
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Dropbox" "$FAKE/Library/CloudStorage"
ln -s "$FAKE/Dropbox" "$FAKE/Library/CloudStorage/Dropbox-Mirror"
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")
$(line "$FAKE/Library/CloudStorage/Dropbox-Mirror" 'Dropbox-Mirror')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "symlink duplicate (CloudStorage root -> ~/Dropbox): one entry"
else
  bad "symlink duplicate" "rc=$RC got: $(show "$OUT")"
fi
rm -rf "$FAKE"

# 6. --help documents the flag
if "$ROOT/backup.sh" --help 2>&1 | grep -q -- --list-destinations; then
  ok "--help documents --list-destinations"
else
  bad "--help" "no mention of --list-destinations"
fi

# 7. glob METACHARACTERS in a resolved path must match LITERALLY in the dedupe seen-set:
#    it is a case PATTERN, so an unquoted expansion turns [1] into a character class and
#    silently suppresses the distinct directory MyDrive[1] because MyDrive1 is seen.
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/MyDrive1" \
         "$FAKE/Library/CloudStorage/MyDrive[1]"
run_list "$FAKE"
EXPECTED="$(line "$FAKE/claude-migration" "$DEFAULT_LABEL")
$(line "$FAKE/Library/CloudStorage/MyDrive1" 'MyDrive1')
$(line "$FAKE/Library/CloudStorage/MyDrive[1]" 'MyDrive[1]')"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  ok "glob metachars in path dedupe LITERALLY: MyDrive1 and MyDrive[1] both listed"
else
  bad "glob metachars in path dedupe" "rc=$RC got: $(show "$OUT")"
fi
rm -rf "$FAKE"

# --- Task 2: the interactive destination menu (TTY-gated multi-select) ---------

PTYOUT="$HERE/.tmp-pty.out"
trap '[ -n "$FAKE" ] && rm -rf "$FAKE"; rm -f "$PTYOUT"' EXIT

run_menu() {  # run_menu <fake-home> <keys>... -- pty --dry-run run, keys paced 1.5s
              # apart (flat input races the child; see header). An initial sleep lets the
              # child reach its first read before the first key (the one race that ate
              # keystrokes in the flat probes). Sets RC + PTYOUT.
  FAKE="$1"; shift
  {
    sleep 1
    for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done
  } | HOME="$FAKE" script -q /dev/null /bin/bash "$ROOT/backup.sh" --dry-run >"$PTYOUT" 2>&1
  RC=$?
}
run_menu_out() {  # like run_menu but WITH a positional OUT: the menu must stay shut
  FAKE="$1"; OUTARG="$2"; shift 2
  {
    for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done
  } | HOME="$FAKE" script -q /dev/null /bin/bash "$ROOT/backup.sh" --dry-run "$OUTARG" >"$PTYOUT" 2>&1
  RC=$?
}
run_menu_stdout_file() {  # stdin = tty (the pty), stdout = a FILE (redirected INSIDE
                          # the pty): a menu here would hang `backup.sh | tee log`
  FAKE="$1"; shift
  {
    for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done
  } | HOME="$FAKE" script -q /dev/null /bin/bash -c 'exec /bin/bash "$1" --dry-run > "$2" 2>&1' \
      menu-stdout-file "$ROOT/backup.sh" "$FAKE/redir.log" >"$PTYOUT" 2>&1
  RC=$?
}
run_menu_stdin_devnull() {  # stdout = tty (the pty), stdin = /dev/null (redirected
                            # INSIDE the pty): a piped-stdin caller must get no menu
  FAKE="$1"
  HOME="$FAKE" script -q /dev/null /bin/bash -c 'exec /bin/bash "$1" --dry-run < /dev/null' \
    menu-stdin-devnull "$ROOT/backup.sh" >"$PTYOUT" 2>&1
  RC=$?
}
run_menu_nokeys() {  # stdin held open 2s, then EOF: a prompt that reads EOF must
                     # abort, never spin
  FAKE="$1"
  ( sleep 2 ) | HOME="$FAKE" script -q /dev/null /bin/bash "$ROOT/backup.sh" --dry-run >"$PTYOUT" 2>&1
  RC=$?
}
menu_out() { tr -d '\r' < "$PTYOUT"; }      # pty output, CR line-endings stripped
RULE72="$(printf '%72s' '' | tr ' ' '=')"   # the menu's "=" * 72 rule, built not typed

# 8. Enter alone: the default OUT is used (--dry-run shows it as the archive path)
FAKE=$(mktemp -d)
run_menu "$FAKE" ""
if [ "$RC" -eq 0 ] && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration"; then
  ok "Enter alone: DRY RUN shows the default OUT"
else
  bad "Enter alone" "rc=$RC got: $(menu_out | tail -5 | tr '\n' '|')"
fi

# 9. the pinned menu block: title, subtitle, the =x72 rule, entry 1 with label AND
#    the default's path indented under it, both footer lines
if menu_out | grep -Fq '📦 Mac Claude Migration' \
   && menu_out | grep -Fq '   Where should this backup go? Pick one, several, or a custom folder' \
   && menu_out | grep -Fq "$RULE72" && ! menu_out | grep -Eq '={73}' \
   && menu_out | grep -Fq '  1) Default — this is where the archive is built' \
   && menu_out | grep -Fq "     $FAKE/claude-migration" \
   && menu_out | grep -Fq '  Enter = default only    numbers = pick several (e.g. 1 3 or 1,3)    a = all detected' \
   && menu_out | grep -Fq '  c = custom directory    q = abort the backup'; then
  ok "menu block: title/subtitle/rule x72/entry 1 + path/footer verbatim"
else
  bad "menu block" "missing pinned text; got: $(menu_out | head -12 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 10. "2 1": several picks, FIRST picked is primary -- the archive goes to
#     candidate 2, and the chosen-set line carries both paths in pick order
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot" "$FAKE/Dropbox"
run_menu "$FAKE" "2 1"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/Library/CloudStorage/CloudRoot/claude-migration-" \
   && ! menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-"; then
  ok "2 1: primary = FIRST picked (candidate 2 gets the archive)"
else
  bad "2 1 primary" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
if menu_out | grep -Fq "Destinations: $FAKE/Library/CloudStorage/CloudRoot (primary), $FAKE/claude-migration"; then
  ok "2 1: chosen-set line lists both paths, pick order"
else
  bad "2 1 chosen-set line" "got: $(menu_out | grep -i destination | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 11. "2,1": the comma form of the same grammar
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot"
run_menu "$FAKE" "2,1"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/Library/CloudStorage/CloudRoot/claude-migration-" \
   && menu_out | grep -Fq "Destinations: $FAKE/Library/CloudStorage/CloudRoot (primary), $FAKE/claude-migration"; then
  ok "2,1: comma-separated picks work, same result as 2 1"
else
  bad "2,1" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 12. "a": every LISTED candidate, default first (primary) -- the default is
#     candidate 1 of the list the user sees (controller ruling on the grammar)
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot" "$FAKE/Dropbox"
run_menu "$FAKE" "a"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Destinations: $FAKE/claude-migration (primary), $FAKE/Library/CloudStorage/CloudRoot, $FAKE/Dropbox" \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-"; then
  ok "a: all listed candidates, default first (primary)"
else
  bad "a all-listed" "rc=$RC got: $(menu_out | grep -iE 'destination|archive' | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 13. "q": abort -- exit 1, the pinned message, nothing else printed
FAKE=$(mktemp -d)
run_menu "$FAKE" "q"
if [ "$RC" -eq 1 ] \
   && menu_out | grep -Fq 'backup aborted — nothing was written' \
   && ! menu_out | grep -q 'DRY RUN' \
   && ! menu_out | grep -q 'Would write archive'; then
  ok "q: exit 1, aborted, no archive path printed"
else
  bad "q abort" "rc=$RC got: $(menu_out | tail -3 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 14. nothing detected (bare fake HOME): only the default is offered, and it is
#     what Enter picks (the "a collapses to default" case has the same list)
FAKE=$(mktemp -d)
run_menu "$FAKE" ""
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-" \
   && menu_out | grep -Fq "Destinations: $FAKE/claude-migration (primary)" \
   && ! menu_out | grep -Fq "$FAKE/claude-migration (primary)," \
   && ! menu_out | grep -Eq '^ +2\)'; then
  ok "empty detection list: only the default is offered and chosen"
else
  bad "empty detection list" "rc=$RC got: $(menu_out | tail -8 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 15. GATE PIN: a positional OUT + a full pty must NOT open the menu -- the piped
#     "q" is never consumed and the run reports the positional OUT
FAKE=$(mktemp -d)
run_menu_out "$FAKE" "$FAKE/chosen-out" "q"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/chosen-out/claude-migration-" \
   && ! menu_out | grep -Fq 'Mac Claude Migration'; then
  ok "positional OUT + pty: no menu, the argument wins"
else
  bad "positional OUT + pty" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 16. GATE PIN (stdout half): stdin is a tty but stdout is a FILE -- a menu here
#     would hang `backup.sh | tee log`; the piped "q" must never be consumed
FAKE=$(mktemp -d)
run_menu_stdout_file "$FAKE" "q"
if [ "$RC" -eq 0 ] \
   && grep -Fq 'DRY RUN' "$FAKE/redir.log" \
   && ! grep -Fq 'Mac Claude Migration' "$FAKE/redir.log"; then
  ok "stdout not a tty (stdin tty): no menu -- piped stdout stays silent"
else
  bad "stdout not a tty" "rc=$RC log: $(tr -d '\r' < "$FAKE/redir.log" | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 17. GATE PIN (stdin half): stdout is a tty but stdin is /dev/null -- no menu,
#     no prompts on the tty for a piped-stdin caller
FAKE=$(mktemp -d)
run_menu_stdin_devnull "$FAKE"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'DRY RUN' \
   && ! menu_out | grep -Fq 'Mac Claude Migration'; then
  ok "stdin not a tty (stdout tty): no menu"
else
  bad "stdin not a tty" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 18. EOF at the prompt: abort like q -- never loop forever on a closed pipe
FAKE=$(mktemp -d)
run_menu_nokeys "$FAKE"
if [ "$RC" -eq 1 ] \
   && menu_out | grep -Fq 'backup aborted — nothing was written' \
   && ! menu_out | grep -q 'DRY RUN'; then
  ok "EOF at the prompt: aborts like q (rc 1, nothing written)"
else
  bad "EOF abort" "rc=$RC got: $(menu_out | tail -3 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 19. custom: an EXISTING directory is accepted as-is (trailing "/" trimmed)
FAKE=$(mktemp -d)
mkdir -p "$FAKE/custom-dest"
run_menu "$FAKE" "c" "$FAKE/custom-dest/"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/custom-dest/claude-migration-" \
   && menu_out | grep -Fq "Destinations: $FAKE/custom-dest (primary)"; then
  ok "custom existing dir: accepted, trailing slash trimmed"
else
  bad "custom existing" "rc=$RC got: $(menu_out | tail -5 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 20. custom: a missing directory is created only after a [y/N] confirm -- and a
#     --dry-run run ANNOUNCES the mkdir without performing it
FAKE=$(mktemp -d)
run_menu "$FAKE" "c" "$FAKE/new-dir" "y"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'does not exist. Create it? [y/N]' \
   && menu_out | grep -Fq '(dry run: would create' \
   && menu_out | grep -Fq "Would write archive: $FAKE/new-dir/claude-migration-" \
   && [ ! -d "$FAKE/new-dir" ]; then
  ok "custom missing dir + y under --dry-run: announced, not created"
else
  bad "custom mkdir dry-run" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 21. custom: declining the create ([n]) returns to the menu -- then Enter = default
FAKE=$(mktemp -d)
run_menu "$FAKE" "c" "$FAKE/nope" "n" ""
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-" \
   && [ ! -e "$FAKE/nope" ]; then
  ok "custom declined: back to the menu, Enter = default, nothing created"
else
  bad "custom declined" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 22. custom: a leading ~ expands against HOME (a literal "~" directory would be
#     a trap -- mkdir would silently create it in the cwd)
FAKE=$(mktemp -d)
run_menu "$FAKE" "c" "~/custom-dest" "y"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/custom-dest/claude-migration-" \
   && [ ! -e "$FAKE/~" ]; then
  ok "custom ~/path expands against HOME"
else
  bad "custom tilde" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 23. garbage input re-asks (menu re-rendered), then a valid pick proceeds
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot"
run_menu "$FAKE" "banana" "2"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'Unrecognized selection' \
   && menu_out | grep -Fq "Would write archive: $FAKE/Library/CloudStorage/CloudRoot/claude-migration-"; then
  ok "garbage re-asks, then a valid pick proceeds"
else
  bad "garbage re-ask" "rc=$RC got: $(menu_out | tail -6 | tr '\n' '|')"
fi
rm -rf "$FAKE"

run_menu_real() {  # like run_menu but a REAL run (no --dry-run); fast — HOME is the fake
  FAKE="$1"; shift
  {
    for k in "$@"; do printf '%s\n' "$k"; sleep 1.5; done
  } | HOME="$FAKE" script -q /dev/null /bin/bash "$ROOT/backup.sh" >"$PTYOUT" 2>&1
  RC=$?
}

# --- Task 3: multi-destination write -------------------------------------------

# 24. "2 1" real run: archive BUILT in candidate 2 (primary), copied to the default;
#     both exist, byte sizes equal, DONE line lists every destination, primary first
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot"
run_menu_real "$FAKE" "2 1"
PRIM="$FAKE/Library/CloudStorage/CloudRoot"
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$PRIM" -name 'claude-migration-*.tar.gz')" ] \
   && [ -n "$(find "$FAKE/claude-migration" -name 'claude-migration-*.tar.gz')" ] \
   && [ "$(stat -f %z "$PRIM"/claude-migration-*.tar.gz)" = "$(stat -f %z "$FAKE/claude-migration"/claude-migration-*.tar.gz)" ] \
   && menu_out | grep -Fq "DONE. Archive: $PRIM/claude-migration-" \
   && menu_out | grep -Fq "destinations: $PRIM (primary), $FAKE/claude-migration"; then
  ok "2 1 real run: built in primary, copied to default, sizes equal, DONE lists all"
else
  bad "2 1 real multi-dest" "rc=$RC got: $(menu_out | tail -5 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 25. unwritable secondary: warn names it, primary archive intact, rc 0
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/Locked"
chmod 000 "$FAKE/Library/CloudStorage/Locked"
run_menu_real "$FAKE" "1 2"
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$FAKE/claude-migration" -name 'claude-migration-*.tar.gz')" ] \
   && menu_out | grep -Fq "could not copy to $FAKE/Library/CloudStorage/Locked"; then
  ok "unwritable secondary: warned, skipped, primary intact, rc 0"
else
  bad "unwritable secondary" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
chmod 755 "$FAKE/Library/CloudStorage/Locked"
rm -rf "$FAKE"

# 26. duplicate pick "1 1": one destination, no self-copy, DONE line has no destinations suffix
FAKE=$(mktemp -d)
run_menu_real "$FAKE" "1 1"
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$FAKE/claude-migration" -name 'claude-migration-*.tar.gz')" ] \
   && menu_out | grep -Fq "DONE. Archive:" \
   && ! menu_out | grep -q "destinations:" \
   && ! menu_out | grep -q "could not copy"; then
  ok "1 1 duplicate: deduped, single-destination DONE unchanged"
else
  bad "1 1 duplicate" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 27. piped positional run (no pty): no Destinations line, no copies, DONE unchanged shape
FAKE=$(mktemp -d)
OUT2="$FAKE/positional-out"
HOME="$FAKE" /bin/bash "$ROOT/backup.sh" "$OUT2" </dev/null >"$PTYOUT" 2>&1; RC=$?
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$OUT2" -name 'claude-migration-*.tar.gz')" ] \
   && ! menu_out | grep -q "Destinations:" \
   && menu_out | grep -Fq "DONE. Archive:" \
   && ! menu_out | grep -q "destinations:"; then
  ok "piped positional run: byte-parity (no menu, no copies, plain DONE)"
else
  bad "piped parity" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# --- adopted Task-2-review minors ----------------------------------------------

# 28. "d" = default (the letter form of Enter)
FAKE=$(mktemp -d)
run_menu "$FAKE" "d"
if [ "$RC" -eq 0 ] && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-"; then
  ok "d key: default chosen"
else
  bad "d key" "rc=$RC got: $(menu_out | tail -3 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 29. out-of-range number re-asks, then a valid pick proceeds
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot"
run_menu "$FAKE" "99" "2"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'Unrecognized selection' \
   && menu_out | grep -Fq "Would write archive: $FAKE/Library/CloudStorage/CloudRoot/claude-migration-"; then
  ok "99 out of range: re-asks, then 2 picks CloudRoot"
else
  bad "out-of-range" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 30. "*" as the answer must NOT glob-expand into picks (set -f) — re-ask instead.
#     The child CWDs into $FAKE so the planted digit dir IS in its cwd: without set -f
#     the "*" would expand to "1" and pick it — this makes the pin discriminating.
FAKE=$(mktemp -d)
mkdir -p "$FAKE/1"
{
  sleep 1; printf '*\n'; sleep 1.5; printf '1\n'; sleep 1.5
} | HOME="$FAKE" script -q /dev/null /bin/bash -c 'cd "$2" && exec /bin/bash "$1" --dry-run' \
    menu-cd-fake "$ROOT/backup.sh" "$FAKE" >"$PTYOUT" 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'Unrecognized selection' \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-" \
   && ! menu_out | grep -Fq "Would write archive: $FAKE/1/claude-migration-"; then
  ok "'*' answer: re-asks (no glob expansion into the planted digit dir)"
else
  bad "glob answer" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 31. bare Enter at the custom-dir prompt re-asks instead of mkdir ""
FAKE=$(mktemp -d)
run_menu "$FAKE" "c" "" "1"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-" \
   && ! menu_out | grep -Fq 'does not exist. Create it?'; then
  ok "bare Enter at custom prompt: re-asks, no empty mkdir"
else
  bad "empty custom dir" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 32. missing AND uncreatable secondary (default picked as secondary under a read-only
#     HOME): mkdir -p fails -> warn + skip, rc 0, primary archive intact. Under set -e an
#     UNGUARDED mkdir would abort the whole script here (no DONE, staging left behind).
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/CloudRoot"
chmod 555 "$FAKE"
run_menu_real "$FAKE" "2 1"
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$FAKE/Library/CloudStorage/CloudRoot" -name 'claude-migration-*.tar.gz')" ] \
   && menu_out | grep -Fq "could not copy to $FAKE/claude-migration" \
   && menu_out | grep -Fq "DONE. Archive:"; then
  ok "uncreatable missing secondary: warned, skipped, rc 0, DONE printed, primary intact"
else
  bad "uncreatable secondary" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
chmod 755 "$FAKE"
rm -rf "$FAKE"

# 33. END-TO-END: a SPACE-NAMED cloud root selected through the pty menu — the review
#     flagged the space pin as listing-only; here the path travels menu -> DESTS -> archive
FAKE=$(mktemp -d)
mkdir -p "$FAKE/Library/CloudStorage/GoogleDrive-1 My Drive"
run_menu_real "$FAKE" "2"
if [ "$RC" -eq 0 ] \
   && [ -n "$(find "$FAKE/Library/CloudStorage/GoogleDrive-1 My Drive" -name 'claude-migration-*.tar.gz')" ] \
   && menu_out | grep -Fq "DONE. Archive: $FAKE/Library/CloudStorage/GoogleDrive-1 My Drive/claude-migration-"; then
  ok "space-named root: selected through the menu, archive lands there"
else
  bad "space-named root e2e" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 34. a 20-digit token must RE-ASK: bash `[` errors (rc 2) on the overflow, the old
#     range-check fell through as "valid", and the resolution index aborted the subshell
FAKE=$(mktemp -d)
run_menu "$FAKE" "12345678901234567890" "1"
if [ "$RC" -eq 0 ] \
   && menu_out | grep -Fq 'Unrecognized selection' \
   && menu_out | grep -Fq "Would write archive: $FAKE/claude-migration/claude-migration-"; then
  ok "20-digit token: re-asks (no integer-overflow pass-through)"
else
  bad "int overflow" "rc=$RC got: $(menu_out | tail -4 | tr '\n' '|')"
fi
rm -rf "$FAKE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
