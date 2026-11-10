#!/bin/bash
# End-to-end for repo auto-discovery (plan Task 6 / handoff §5.4): the five-part
# fake HOME — a repo with a remote, a repo with no remote, a linked worktree,
# a repo under a pruned path (~/Library/...), and a repo under .claude — is
# backed up (run 1 non-terminal: bare lines for remote+worktree, ? for
# no-remote, nothing for pruned paths), then re-run on a pty with a seeded
# + line and ! line (run 2: copy tarball built, excluded stays out,
# remembered-choices line printed), then RESTORED into a fresh fake HOME
# (remote repo cloned + checked out at the recorded SHA, + repo extracted
# with .git, excluded repo absent). Also pins TOOL_VERSION=0.2.0 in the
# archive meta.env and --reset-choices in --help. Hermetic: fake HOMEs,
# local-path remotes, stubbed brew/pipx, alarm-guarded non-terminal runs.
#
# Usage: test_e2e.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
FAKE=""; OUT=""; OUT2=""; RH=""; ORIGIN=""
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  [ -n "$OUT2" ] && rm -rf "$OUT2"
  [ -n "$RH" ] && rm -rf "$RH"
  [ -n "$ORIGIN" ] && rm -rf "$ORIGIN"
  rm -rf "$STUB" "$HERE/.tmp-pty-e2e.out"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT
mkrepo() {  # mkrepo <abs-path> [origin-url]
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  printf 'content\n' > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null
  if [ -n "${2:-}" ]; then git -C "$d" remote add origin "$2" 2>/dev/null; fi
}
PTYOUT="$HERE/.tmp-pty-e2e.out"

# --- five-part fake HOME ---------------------------------------------------------
FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
OUT=$(mktemp -d); rm -rf "$OUT"; mkdir -p "$OUT"
OUT2=$(mktemp -d); rm -rf "$OUT2"; mkdir -p "$OUT2"
ORIGIN=$(mktemp -d); rm -rf "$ORIGIN"
git init -q --bare "$ORIGIN/rem.git" 2>/dev/null
mkrepo "$FAKE/rem" "$ORIGIN/rem.git"
git -C "$FAKE/rem" push -q origin HEAD 2>/dev/null
mkrepo "$FAKE/local"                                   # no remote
mkrepo "$FAKE/Library/planted"                         # pruned path
mkrepo "$FAKE/.claude/plans/x"                         # under .claude (pruned)
git -C "$FAKE/rem" worktree add -q "$FAKE/wt" 2>/dev/null   # linked worktree
LIST="$FAKE/.claude-migration-repos"

# --- run 1: non-terminal ---------------------------------------------------------
out=$(env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
      perl -e 'alarm 90; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null 2>&1); RC=$?
arch=""; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
if [ "$RC" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'repos: 2 recorded, 0 copied whole, 0 excluded, 1 undecided, 0 missing' \
   && grep -Fqx 'rem' "$LIST" && grep -Fqx 'wt' "$LIST" && grep -Fqx '?local' "$LIST" \
   && ! grep -q 'planted' "$LIST" && ! grep -q 'plans/x' "$LIST" \
   && [ "$(grep -c '^# Repo list for backup.sh' "$LIST")" -eq 1 ] \
   && [ -n "$arch" ]; then
  ok "run 1 (non-terminal): remote+worktree bare, no-remote ?, pruned paths absent, header written"
else
  bad "run 1" "RC=$RC list=$(tr '\n' '|' < "$LIST" 2>/dev/null) out=$(printf '%s' "$out" | grep -a 'repos:' | head -1)"
fi
TSV1="$(tar -xzOf "$arch" ./repos.tsv 2>/dev/null)"
META="$(tar -xzOf "$arch" ./meta.env 2>/dev/null)"
if printf '%s' "$TSV1" | grep -q $'^rem\t' && printf '%s' "$TSV1" | grep -q $'^wt\t' \
   && ! printf '%s' "$TSV1" | grep -q 'local' \
   && ! printf '%s' "$TSV1" | grep -q 'planted' \
   && ! printf '%s' "$TSV1" | grep -q 'plans/x'; then
  ok "run 1 archive repos.tsv: only rem + wt recorded (pruned paths never listed)"
else
  bad "run 1 tsv" "$(printf '%s' "$TSV1" | tr '\n' '|')"
fi
if printf '%s' "$META" | grep -q '^TOOL_VERSION=0.2.0$'; then
  ok "archive meta.env pins TOOL_VERSION=0.2.0"
else
  bad "TOOL_VERSION" "meta: $(printf '%s' "$META" | grep TOOL_VERSION)"
fi

# --- run 2: pty, seeded + and ! lines ---------------------------------------------
sed -i '' -e 's/^?local$/+local/' -e 's/^wt$/!wt/' "$LIST" 2>/dev/null || sed -i -e 's/^?local$/+local/' -e 's/^wt$/!wt/' "$LIST"
# keys paced like test_destinations (1.5 s after each key — the measured race)
{ sleep 1; printf '\n'; sleep 1.5; } | env -u MIGRATION_REPOS HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    script -q /dev/null /bin/bash "$ROOT/backup.sh" "$OUT2" >"$PTYOUT" 2>&1
RC2=$?
arch2=""; for a in "$OUT2"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch2="$a"; done
c_rc=$([ "$RC2" -eq 0 ] && echo y || echo n)
c_line=$(tr -d '\r' < "$PTYOUT" | grep -q 'using remembered choices' && echo y || echo n)
c_pl=$(grep -Fqx '+local' "$LIST" && echo y || echo n)
c_wt=$(grep -Fqx '!wt' "$LIST" && echo y || echo n)
c_arch=$([ -n "$arch2" ] && echo y || echo n)
c_tgz=$(tar -tzf "$arch2" 2>/dev/null | grep -q '^\./repo-copies/local\.tar\.gz$' && echo y || echo n)
if [ "$c_rc$c_line$c_pl$c_wt$c_arch$c_tgz" = "yyyyyy" ]; then
  ok "run 2 (pty): remembered-choices line, +local copy tarball built, !wt stays excluded"
else
  bad "run 2" "rc=$c_rc line=$c_line +local=$c_pl !wt=$c_wt arch=$c_arch tgz=$c_tgz tgzlist=$(tar -tzf "$arch2" 2>/dev/null | grep -a repo-copies | tr '\n' '|')"
fi
TSV2="$(tar -xzOf "$arch2" ./repos.tsv 2>/dev/null)"
if printf '%s' "$TSV2" | grep -q $'^rem\t'"$ORIGIN/rem.git" \
   && printf '%s' "$TSV2" | grep -q $'^local\t\t' \
   && ! printf '%s' "$TSV2" | grep -q $'^wt\t'; then
  ok "run 2 repos.tsv: rem keeps its URL, local has the empty-URL copy row, wt gone"
else
  bad "run 2 tsv" "$(printf '%s' "$TSV2" | tr '\t' '|' | tr '\n' '|')"
fi

# --- restore the run-2 archive into a fresh fake HOME ------------------------------
RH=$(mktemp -d); rm -rf "$RH"; mkdir -p "$RH"
rout=$(env -u MIGRATION_REPOS HOME="$RH" PATH="$STUB:$SAVED_PATH" \
       perl -e 'alarm 150; exec @ARGV' /bin/bash "$ROOT/restore.sh" "$arch2" </dev/null 2>&1); RRC=$?
remsha="$(printf '%s' "$TSV2" | grep $'^rem\t' | awk -F'\t' '{print $4}')"
if [ "$RRC" -eq 0 ] \
   && [ -f "$RH/rem/seed.txt" ] && [ "$(git -C "$RH/rem" rev-parse HEAD 2>/dev/null)" = "$remsha" ] \
   && [ -f "$RH/local/.git/HEAD" ] && [ -f "$RH/local/seed.txt" ] \
   && [ ! -e "$RH/wt" ]; then
  ok "restore: rem cloned + checked out at recorded SHA, +local extracted with .git, !wt absent"
else
  bad "restore" "RRC=$RRC rem=$([ -f "$RH/rem/seed.txt" ] && echo y) sha=$(git -C "$RH/rem" rev-parse HEAD 2>/dev/null | cut -c1-8)/$([ -n "$remsha" ] && echo "${remsha:0:8}") localgit=$([ -f "$RH/local/.git/HEAD" ] && echo y) wt=$([ -e "$RH/wt" ] && echo PRESENT)"
fi

# --- --help documents the new flag -------------------------------------------------
if "$ROOT/backup.sh" --help 2>&1 | grep -q -- '--reset-choices'; then
  ok "--help documents --reset-choices"
else
  bad "--help" "missing --reset-choices"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
