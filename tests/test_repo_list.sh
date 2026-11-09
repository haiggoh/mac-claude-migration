#!/bin/bash
# List-file I/O + merge contract for repo auto-discovery (plan Task 2).
# `_read_repo_list` parses the repo list into `state<TAB>payload` lines
# (record|exclude|copy|undecided|comment): `!`/`+`/`?` prefixes map to
# exclude/copy/undecided, any other line is a bare record; `~/` prefixes,
# trailing `/`, CR (CRLF files) and surrounding whitespace are stripped; `#`
# comments and blank lines are carried verbatim as `comment` state so a rewrite
# of the file is lossless. `_write_repo_list` converts merged state lines back
# to file lines, prepends the generated header only when creating, and writes
# atomically (mktemp in the same dir + mv — the inode must change on rewrite
# and no temp file may remain). `_merge_repos` consumes read lines on stdin plus
# discovered $HOME-relative paths as args and sets DECIDED_*, NEW_REMOTE,
# NEW_NOREMOTE, MISSING (listed but not on disk: warned, line kept), MERGE_LINES.
#
# The functions live inside backup.sh (it must stay a standalone file for the
# brew/tap distribution), so the suite extracts them by sed range; an empty
# extraction FAILS LOUDLY — a silent no-op would pass every case below while
# testing nothing.
#
# Usage: test_repo_list.sh [--help]
set -u
export LC_ALL=C   # pin order: list parsing must be deterministic
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"

# --- harness -------------------------------------------------------------------
load_fn() {  # load_fn <name> — extract `name() { ... }` from backup.sh; empty = FAIL
  local name="$1" src
  src="$(sed -n "/^${name}() {/,/^}/p" "$ROOT/backup.sh")"
  if [ -z "$src" ]; then
    bad "load_fn $1" "empty extraction — function missing or style drifted"
    return 1
  fi
  eval "$src"
}
WARNS=""
log()  { :; }   # stubs: extracted functions may call the script's loggers
warn() { WARNS="${WARNS}${WARNS:+$'\n'}$*"; }
mkrepo() {  # mkrepo <abs-path> [origin-url] — init + empty commit (+ origin)
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "${2:-}" ]; then git -C "$d" remote add origin "$2" 2>/dev/null; fi
}
FAKE=""
trap '[ -n "$FAKE" ] && rm -rf "$FAKE"; HOME="$SAVED_HOME"' EXIT

load_fn _read_repo_list
load_fn _write_repo_list
load_fn _merge_repos
load_fn _merge_decided
load_fn _repo_remote
# Barrier: without these functions no case below can test anything — refuse to
# run rather than emit spurious oks (an empty extraction is a failure).
if ! declare -F _read_repo_list >/dev/null 2>&1 || ! declare -F _write_repo_list >/dev/null 2>&1 \
   || ! declare -F _merge_repos >/dev/null 2>&1 || ! declare -F _repo_remote >/dev/null 2>&1; then
  printf '  FAIL list functions missing from backup.sh — suite cannot run\n'
  exit 1
fi

# 1. each prefix parses to its state
FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
LIST="$FAKE/repos"
printf 'alpha\n!beta\n+gamma\n?delta\n' > "$LIST"
out=$(_read_repo_list "$LIST"); rc=$?
expected="$(printf 'record\talpha\nexclude\tbeta\ncopy\tgamma\nundecided\tdelta')"
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
  ok "prefixes parse: bare/!/+/ ? -> record/exclude/copy/undecided"
else
  bad "prefix parse" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi

# 2. `#` comments and blank lines are carried verbatim as comment state — but a
#    CRLF comment line must come back CR-FREE (pins the explicit CR strip: the
#    whitespace trim alone would leave the CR in the verbatim payload)
printf '# top\n\n   # indented\nalpha\n# tail\r\n' > "$LIST"
out=$(_read_repo_list "$LIST")
expected="$(printf 'comment\t# top\ncomment\t\ncomment\t   # indented\nrecord\talpha\ncomment\t# tail')"
if [ "$out" = "$expected" ]; then
  ok "comments + blank lines carried verbatim as comment state"
else
  bad "comment state" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi

# 3. normalization: `~/` prefix, trailing `/`, CR (CRLF), surrounding whitespace
# shellcheck disable=SC2088  # the quoted '~/' is the POINT: the fixture must hold a literal tilde
printf '~/home/x\ntrail/\ncrlf\r\n  spaced  \n' > "$LIST"
out=$(_read_repo_list "$LIST")
expected="$(printf 'record\thome/x\nrecord\ttrail\nrecord\tcrlf\nrecord\tspaced')"
if [ "$out" = "$expected" ]; then
  ok "read normalizes ~/ prefix, trailing /, CR, surrounding whitespace"
else
  bad "normalization" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi

# 4. rewrite is canonical: `~/x/` comes back as bare `x`
# shellcheck disable=SC2088  # quoted '~/' is literal on purpose (fixture)
printf '~/x/\n' > "$LIST"
_write_repo_list "$LIST" "$(_read_repo_list "$LIST")"
if [ "$(cat "$LIST")" = "x" ]; then
  ok "rewrite writes canonical \$HOME-relative paths (~/x/ -> x)"
else
  bad "canonical rewrite" "got: $(cat "$LIST")"
fi

# 5. an unknown prefix is a bare record and survives a read-write cycle literally
printf '@keepme\n' > "$LIST"
out=$(_read_repo_list "$LIST")
OUT2="$FAKE/repos2"
_write_repo_list "$OUT2" "$out"
if [ "$out" = "$(printf 'record\t@keepme')" ] && grep -Fqx '@keepme' "$OUT2"; then
  ok "unknown-prefix line is a record and survives the read-write cycle"
else
  bad "unknown prefix" "read: $(printf '%s' "$out" | tr '\n' '|'); file: $(cat "$OUT2" 2>/dev/null | tr '\n' '|')"
fi

# 6. generated header written on create, exactly once across rewrites (the real
#    flow always reads first, so the header comes back as comment lines)
OUT3="$FAKE/repos3"
_write_repo_list "$OUT3" "$(printf 'record\ta\n')"
n1=$(grep -c '^# Repo list for backup.sh' "$OUT3")
_write_repo_list "$OUT3" "$(_read_repo_list "$OUT3")$(printf '\nrecord\tb')"
n2=$(grep -c '^# Repo list for backup.sh' "$OUT3")
if [ "$n1" -eq 1 ] && [ "$n2" -eq 1 ]; then
  ok "header prepended on create, not duplicated on rewrite"
else
  bad "header" "after create: $n1, after rewrite: $n2"
fi

# 7. user comments and line order survive a rewrite byte-identically
printf '# top\nalpha\n\n# mid\n!beta\n' > "$LIST"
cp "$LIST" "$LIST.orig"
_write_repo_list "$LIST" "$(_read_repo_list "$LIST")"
if cmp -s "$LIST" "$LIST.orig"; then
  ok "rewrite is lossless: comments + order byte-identical (cmp)"
else
  bad "lossless rewrite" "diff: $(diff "$LIST.orig" "$LIST" | tr '\n' '|')"
fi
rm -f "$LIST.orig"

# 8. new entries land at the end, existing order intact
printf 'alpha\n' > "$LIST"
_write_repo_list "$LIST" "$(_read_repo_list "$LIST")
$(printf 'record\tnewer')"
if [ "$(head -n 1 "$LIST")" = "alpha" ] && [ "$(tail -n 1 "$LIST")" = "newer" ]; then
  ok "new entries appended at end, existing order intact"
else
  bad "append" "file: $(cat "$LIST" | tr '\n' '|')"
fi

# 9. atomic write: no temp leftovers, content complete, inode changes on rewrite
LIST9="$FAKE/repos9"
_write_repo_list "$LIST9" "$(printf 'record\tone\n')"
leftovers=$(find "$FAKE" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')
inode1=$(stat -f %i "$LIST9")
_write_repo_list "$LIST9" "$(_read_repo_list "$LIST9")$(printf '\nrecord\ttwo')"
inode2=$(stat -f %i "$LIST9")
leftovers2=$(find "$FAKE" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')
if [ "$leftovers" -eq 0 ] && [ "$leftovers2" -eq 0 ] \
   && [ "$(tail -n 1 "$LIST9")" = "two" ] \
   && [ "$(grep -c '^# Repo list for backup.sh' "$LIST9")" -eq 1 ] \
   && [ "$inode1" != "$inode2" ]; then
  ok "atomic write: temp cleaned, content complete, inode changed (temp+mv, not direct write)"
else
  bad "atomic write" "leftovers=$leftovers/$leftovers2 inode=$inode1->$inode2 tail=$(tail -n 1 "$LIST9")"
fi

# 10. a missing list file reads as empty, rc 0
out=$(_read_repo_list "$FAKE/does-not-exist"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "missing list file: empty output, rc 0"
else
  bad "missing file" "rc=$rc got: $out"
fi

# 11. merge: decided vs new vs missing; missing warns and its line is kept
rm -rf "$FAKE"; FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
mkrepo "$FAKE/here" "https://example.com/here.git"
mkrepo "$FAKE/fresh" "https://example.com/fresh.git"
mkrepo "$FAKE/local"
printf 'here\ngone\n' > "$FAKE/repos"
_read_repo_list "$FAKE/repos" > "$FAKE/lines"
WARNS=""
HOME="$FAKE"; _merge_repos here fresh local < "$FAKE/lines"; rc=$?
HOME="$SAVED_HOME"
new_all=" $(printf '%s ' ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"} ${NEW_NOREMOTE[@]+"${NEW_NOREMOTE[@]}"}) "
ml="$(printf '%s\n' ${MERGE_LINES[@]+"${MERGE_LINES[@]}"})"
# (a listed-but-missing repo keeps its decision — DECIDED_RECORD holds it too —
#  and MISSING additionally warns; the line is kept for the rewrite)
if [ "$rc" -eq 0 ] \
   && [ "${DECIDED_RECORD[*]:-x}" = "here gone" ] \
   && [ "${#MISSING[@]}" -eq 1 ] && [ "${MISSING[*]:-x}" = "gone" ] \
   && printf '%s' "$WARNS" | grep -Fq 'listed repo missing: gone' \
   && printf '%s' "$ml" | grep -Fqx "$(printf 'record\tgone')" \
   && [ "${NEW_REMOTE[*]:-x}" = "fresh" ] \
   && [ "${NEW_NOREMOTE[*]:-x}" = "local" ] \
   && case "$new_all" in *" here "*) false ;; *) true ;; esac; then
  ok "merge: listed-on-disk decided, new split by remote, missing warned + line kept"
else
  bad "merge split" "rc=$rc record=[${DECIDED_RECORD[*]:-}] missing=[${MISSING[*]:-}] newr=[${NEW_REMOTE[*]:-}] newnr=[${NEW_NOREMOTE[*]:-}] warns=$WARNS"
fi

# 12. merge: !/+/? decided arrays, and a discovered repo already decided is not re-offered
rm -rf "$FAKE"; FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
mkrepo "$FAKE/skipme"; mkrepo "$FAKE/copied"; mkrepo "$FAKE/parked"
printf '!skipme\n+copied\n?parked\n' > "$FAKE/repos"
_read_repo_list "$FAKE/repos" > "$FAKE/lines"
WARNS=""
HOME="$FAKE"; _merge_repos skipme copied parked < "$FAKE/lines"; rc=$?
HOME="$SAVED_HOME"
new_all=" $(printf '%s ' ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"} ${NEW_NOREMOTE[@]+"${NEW_NOREMOTE[@]}"}) "
if [ "$rc" -eq 0 ] \
   && [ "${DECIDED_EXCLUDE[*]:-x}" = "skipme" ] \
   && [ "${DECIDED_COPY[*]:-x}" = "copied" ] \
   && [ "${DECIDED_UNDECIDED[*]:-x}" = "parked" ] \
   && [ "${#NEW_REMOTE[@]}" -eq 0 ] && [ "${#NEW_NOREMOTE[@]}" -eq 0 ] \
   && [ -z "$WARNS" ] \
   && case "$new_all" in *" skipme "*|*" copied "*|*" parked "*) false ;; *) true ;; esac; then
  ok "merge: !/+/? lines decide, discovered decided repos are not re-offered"
else
  bad "merge decided" "excl=[${DECIDED_EXCLUDE[*]:-}] copy=[${DECIDED_COPY[*]:-}] undec=[${DECIDED_UNDECIDED[*]:-}] newr=[${NEW_REMOTE[*]:-}] newnr=[${NEW_NOREMOTE[*]:-}] warns=$WARNS"
fi

# 13. malformed list files: empty and header-only both parse and merge cleanly
: > "$FAKE/empty"
out=$(_read_repo_list "$FAKE/empty"); rc=$?
HOME="$FAKE"; _merge_repos < "$FAKE/empty"; rc2=$?
HOME="$SAVED_HOME"
printf '# only a comment\n' > "$FAKE/honly"
out2=$(_read_repo_list "$FAKE/honly")
if [ "$rc" -eq 0 ] && [ -z "$out" ] \
   && [ "$rc2" -eq 0 ] \
   && [ "${#DECIDED_RECORD[@]}" -eq 0 ] && [ "${#NEW_REMOTE[@]}" -eq 0 ] \
   && [ "${#NEW_NOREMOTE[@]}" -eq 0 ] && [ "${#MISSING[@]}" -eq 0 ] \
   && [ "$out2" = "$(printf 'comment\t# only a comment')" ]; then
  ok "empty + header-only list files: read rc 0, merge decides nothing"
else
  bad "malformed" "rc=$rc/$rc2 out2=$(printf '%s' "$out2" | tr '\n' '|')"
fi

# 14. no list file at all: every discovered repo is new (remote split applies)
rm -rf "$FAKE"; FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2"
: > "$FAKE/nolines"
WARNS=""
HOME="$FAKE"; _merge_repos r1 r2 < "$FAKE/nolines"; rc=$?
HOME="$SAVED_HOME"
if [ "$rc" -eq 0 ] \
   && [ "${NEW_REMOTE[*]:-x}" = "r1" ] \
   && [ "${NEW_NOREMOTE[*]:-x}" = "r2" ] \
   && [ "${#MISSING[@]}" -eq 0 ] && [ -z "$WARNS" ]; then
  ok "no list file: all discovered repos are new, split by remote"
else
  bad "no list file" "newr=[${NEW_REMOTE[*]:-}] newnr=[${NEW_NOREMOTE[*]:-}] warns=$WARNS"
fi
rm -rf "$FAKE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
