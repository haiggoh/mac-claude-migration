#!/bin/bash
# Destination detection for the destination-selection menu (plan Task 1):
# `backup.sh --list-destinations` prints one "path<TAB>label" line per candidate,
# the default output dir FIRST, then every existing child of ~/Library/CloudStorage/,
# then the legacy dirs (~/Dropbox, ~/OneDrive), then iCloud Drive. Existing
# directories only, deduped by RESOLVED path (a CloudStorage root that is ~/Dropbox
# via a symlink is listed once), space-named roots intact, non-directory junk
# skipped. Every case runs against a fake HOME (mktemp -d), so detection is hermetic.
#
# Usage: test_destinations.sh [--help]
set -u
export LC_ALL=C   # pin glob collation: the detection order must be deterministic
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
