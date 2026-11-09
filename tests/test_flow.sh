#!/bin/bash
# Flow wiring for repo auto-discovery (plan Task 3): with no MIGRATION_REPOS, a
# run discovers repos under $HOME, merges them with ~/.claude-migration-repos
# (prefixes honoured), appends new repos (bare line for remotes, `?` for
# no-remote), writes the list file ONLY when something changed (idempotent
# re-runs rewrite nothing — inode-stable), prints the pinned summary
# `repos: N recorded, N copied whole, N excluded, N undecided, N missing` with
# undecided/missing named on warn lines, and a non-terminal run never prompts
# (proven by stdin </dev/null under a perl alarm). MIGRATION_REPOS keeps the old
# verbatim behaviour: no discovery, no summary, no list-file write.
# --dry-run prints the summary but writes nothing (no list file, no prefs, no
# archive). Real runs happen only against fake HOMEs with brew/pipx stubbed.
#
# Usage: test_flow.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
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
# Hermetic PATH for real runs: real git/tar, stubbed brew + pipx (no network,
# no reads of the real machine's package state).
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
FAKE=""; OUT=""
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  rm -rf "$STUB"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT
# run_backup <fake-home> <out> [args...] — non-terminal (stdin /dev/null) under
# a perl alarm: a run that prompts/hangs dies with SIGALRM (rc 142), not 0.
run_backup() {
  local h="$1" o="$2"; shift 2
  env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$h" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 60; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$o" "$@" </dev/null 2>&1
}
fresh() { FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"; OUT=$(mktemp -d); rm -rf "$OUT"; mkdir -p "$OUT"; }

# 1. full non-terminal run: discovery + merge + append + summary + archive + repos.tsv
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2"
mkrepo "$FAKE/excl"
git -C "$FAKE/r1" worktree add -q "$FAKE/wt" 2>/dev/null
printf '!excl\ngone\n' > "$FAKE/.claude-migration-repos"
out=$(run_backup "$FAKE" "$OUT"); rc=$?
LIST="$FAKE/.claude-migration-repos"
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'repos: 2 recorded, 0 copied whole, 1 excluded, 1 undecided, 1 missing' \
   && printf '%s' "$out" | grep -Fq 'listed repo missing: gone' \
   && printf '%s' "$out" | grep -Fq 'undecided (no remote): r2' \
   && ! printf '%s' "$out" | grep -q 'Where should this backup go'; then
  ok "non-terminal run: rc 0 (no prompt/hang), pinned summary, named warns, no menu"
else
  bad "flow run" "rc=$rc out=$(printf '%s' "$out" | tail -5 | tr '\n' '|')"
fi
if [ -f "$LIST" ] \
   && [ "$(grep -c '^# Repo list for backup.sh' "$LIST")" -eq 0 ] \
   && grep -Fqx '!excl' "$LIST" && grep -Fqx 'gone' "$LIST" \
   && grep -Fqx 'r1' "$LIST" && grep -Fqx 'wt' "$LIST" && grep -Fqx '?r2' "$LIST" \
   && [ "$(grep -vc '^#' "$LIST" | tr -d ' ')" -eq 5 ]; then
  ok "list file: hand-written file preserved (no header injected), old lines kept, new bare/? lines appended"
else
  bad "list file" "content: $(tr '\n' '|' < "$LIST" 2>/dev/null)"
fi
arch=""
for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
if [ -n "$arch" ]; then
  tsv="$(tar -xzOf "$arch" ./repos.tsv 2>/dev/null)"
  # branch-agnostic: the worktree's own branch name may differ per git version
  if printf '%s' "$tsv" | grep -q $'r1\thttps://example.com/r1.git\t' \
     && printf '%s' "$tsv" | grep -q $'wt\thttps://example.com/r1.git' \
     && printf '%s' "$tsv" | grep -q $'wt\thttps://example.com/r1.git' \
     && ! printf '%s' "$tsv" | grep -q 'excl' \
     && ! printf '%s' "$tsv" | grep -q $'r2\t'; then
    ok "archive repos.tsv: remote repo + linked worktree recorded, excluded/? not"
  else
    bad "repos.tsv" "got: $(printf '%s' "$tsv" | tr '\n' '|')"
  fi
else
  bad "archive" "no claude-migration-*.tar.gz in $OUT"
fi

# 2. --dry-run on a fresh HOME with one remote repo: summary printed, nothing written
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
out=$(env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
      /bin/bash "$ROOT/backup.sh" --dry-run </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'DRY RUN' \
   && printf '%s' "$out" | grep -q 'repos: 1 recorded, 0 copied whole, 0 excluded, 0 undecided, 0 missing' \
   && [ ! -e "$FAKE/.claude-migration-repos" ] \
   && [ ! -e "$FAKE/.claude-migration-prefs" ] \
   && [ ! -e "$FAKE/claude-migration" ]; then
  ok "--dry-run: summary printed, no list file, no prefs file, no archive"
else
  bad "dry-run" "rc=$rc list=$([ -e "$FAKE/.claude-migration-repos" ] && echo yes) out=$(printf '%s' "$out" | tail -3 | tr '\n' '|')"
fi

# 3. MIGRATION_REPOS set: old behaviour verbatim — no discovery, no summary, no list write
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2" "https://example.com/r2.git"
out=$(env MIGRATION_REPOS="r1" HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
      perl -e 'alarm 60; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null 2>&1); rc=$?
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
tsv="$(tar -xzOf "$arch" ./repos.tsv 2>/dev/null)"
if [ "$rc" -eq 0 ] \
   && [ ! -e "$FAKE/.claude-migration-repos" ] \
   && ! printf '%s' "$out" | grep -q 'repos: ' \
   && printf '%s' "$tsv" | grep -q 'r1' \
   && ! printf '%s' "$tsv" | grep -q 'r2'; then
  ok "MIGRATION_REPOS: no discovery/summary/file-write; only the env repos recorded"
else
  bad "MIGRATION_REPOS" "rc=$rc list=$([ -e "$FAKE/.claude-migration-repos" ] && echo yes) tsv=$(printf '%s' "$tsv" | tr '\n' '|')"
fi

# 4. second run is idempotent: list file not rewritten (inode stable), same summary
fresh
mkrepo "$FAKE/r1" "https://example.com/r1.git"
mkrepo "$FAKE/r2"
out=$(run_backup "$FAKE" "$OUT"); rc=$?
LIST="$FAKE/.claude-migration-repos"
inode1=$(stat -f %i "$LIST" 2>/dev/null); cp "$LIST" "$FAKE/list.orig"
OUT2=$(mktemp -d); rm -rf "$OUT2"; mkdir -p "$OUT2"
out2=$(run_backup "$FAKE" "$OUT2"); rc2=$?
inode2=$(stat -f %i "$LIST" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] \
   && [ "$inode1" = "$inode2" ] \
   && cmp -s "$LIST" "$FAKE/list.orig" \
   && printf '%s' "$out2" | grep -q 'repos: 1 recorded, 0 copied whole, 0 excluded, 1 undecided, 0 missing'; then
  ok "second run: idempotent — list file untouched (inode stable), same summary"
else
  bad "idempotent" "rc=$rc/$rc2 inode=$inode1->$inode2"
fi
rm -rf "$OUT2"

# 5. truly empty HOME: zero-repos warning + zero summary, no list file, archive still built
fresh
out=$(run_backup "$FAKE" "$OUT"); rc=$?
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'no repos discovered' \
   && printf '%s' "$out" | grep -q 'repos: 0 recorded, 0 copied whole, 0 excluded, 0 undecided, 0 missing' \
   && [ ! -e "$FAKE/.claude-migration-repos" ] \
   && [ -n "$arch" ]; then
  ok "empty HOME: zero warning + zero summary, no list file, archive still produced"
else
  bad "empty HOME" "rc=$rc arch=${arch:+yes} out=$(printf '%s' "$out" | tail -3 | tr '\n' '|')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
