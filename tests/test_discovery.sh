#!/bin/bash
# Discovery contract for repo auto-discovery (plan Task 1): `_discover_repos`
# prints $HOME-relative repo roots, one per line — any directory containing
# `.git` (directory OR linked-worktree FILE), roots at depth <= 4, nested repos
# suppressed, pruned paths never entered (~/Library incl. CloudStorage, cloud
# dirs, caches, the default output dir, and every CAPTURED_WHOLESALE dir the
# archive already captures wholesale). `_repo_remote` resolves origin, else the
# first remote, else empty. The pruned-path cases are ONE PER ENTRY on purpose:
# a dropped prune fails its own case, not a shared one.
#
# The functions live inside backup.sh (it must stay a standalone file for the
# brew/tap distribution), so the suite extracts them by sed range. The
# extraction FAILS LOUDLY on an empty range — a silent no-op would pass every
# case below while testing nothing.
#
# Usage: test_discovery.sh [--help]
set -u
export LC_ALL=C   # pin sort/find order: discovery output must be deterministic
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

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
log()  { :; }   # stubs: extracted functions may call the script's loggers
warn() { :; }
mkrepo() {  # mkrepo <abs-path> [origin-url] — init + empty commit (+ origin)
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "${2:-}" ]; then git -C "$d" remote add origin "$2" 2>/dev/null; fi
}
FAKE=""
trap '[ -n "$FAKE" ] && rm -rf "$FAKE"' EXIT

load_fn _discover_repos
load_fn _repo_remote
# Barrier: without these functions no case below can test anything — refuse to
# run rather than emit spurious oks (an empty extraction is a failure).
if ! declare -F _discover_repos >/dev/null 2>&1 || ! declare -F _repo_remote >/dev/null 2>&1; then
  printf '  FAIL discovery functions missing from backup.sh — suite cannot run\n'
  exit 1
fi

# CAPTURED_WHOLESALE must exist as a single top-level assignment we can source
eval "$(grep '^CAPTURED_WHOLESALE=' "$ROOT/backup.sh" 2>/dev/null)"
if [ -n "${CAPTURED_WHOLESALE:-}" ]; then
  ok "CAPTURED_WHOLESALE defined (got: $CAPTURED_WHOLESALE)"
else
  bad "CAPTURED_WHOLESALE defined" "assignment not found in backup.sh"
fi

# 1. a simple repo with a remote: found, reported $HOME-relative
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/work" "https://example.com/x.git"
out=$(HOME="$FAKE" _discover_repos); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "work" ]; then
  ok "simple repo found as a \$HOME-relative path"
else
  bad "simple repo" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 2. a linked worktree (.git is a FILE) is a root too — the binding depth case:
#    a worktree nested two dirs deep (root depth 3, .git at depth 4), the shape
#    of a per-branch worktree pool like ~/code/.wt/<branch>
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/main" "https://example.com/m.git"
git -C "$FAKE/main" worktree add -q "$FAKE/code/.wt/wt1" 2>/dev/null
out=$(HOME="$FAKE" _discover_repos)
if printf '%s\n' "$out" | grep -Fqx "code/.wt/wt1" \
   && printf '%s\n' "$out" | grep -Fqx "main"; then
  ok "linked worktree (.git FILE) found alongside its main repo"
else
  bad "linked worktree" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 3. a repo nested inside another repo is NOT listed separately (no descending
#    into a repo root)
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/outer"
mkrepo "$FAKE/outer/inner"
out=$(HOME="$FAKE" _discover_repos)
if [ "$out" = "outer" ]; then
  ok "nested repo suppressed (only the outer root listed)"
else
  bad "nested suppression" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 4. pruned paths: a repo planted under EACH is never listed — one case per
#    entry, each with a CONTROL repo in the same run: empty output only counts
#    when the control is found (a broken discovery must not read as "pruned")
FAKE=$(mktemp -d); rm -rf "$FAKE"
PRUNES="Library Dropbox OneDrive .Trash .cache .npm .cargo .rustup go/pkg claude-migration"
for p in $PRUNES ${CAPTURED_WHOLESALE:-}; do
  mkrepo "$FAKE/$p/planted-repo"
  mkrepo "$FAKE/control-repo"
  out=$(HOME="$FAKE" _discover_repos); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "control-repo" ]; then
    ok "prune: repo under ~/$p never entered (control found)"
  else
    bad "prune ~/$p" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  rm -rf "${FAKE:?}/$p" "${FAKE:?}/control-repo"
done

# 4b. the cloud case by its full shape: Library/CloudStorage/<vendor>/repo
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/Library/CloudStorage/DriveX/planted-repo"
mkrepo "$FAKE/control-repo"
out=$(HOME="$FAKE" _discover_repos); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "control-repo" ]; then
  ok "prune: repo under ~/Library/CloudStorage/<vendor> never entered (control found)"
else
  bad "prune CloudStorage" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 5. name prunes apply at ANY depth: node_modules/.venv/venv/__pycache__
FAKE=$(mktemp -d); rm -rf "$FAKE"
for n in node_modules .venv venv __pycache__; do
  mkrepo "$FAKE/proj/$n/planted-repo"
  mkrepo "$FAKE/control-repo"
  out=$(HOME="$FAKE" _discover_repos); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "control-repo" ]; then
    ok "name prune: repo under proj/$n/ never entered (control found)"
  else
    bad "name prune $n" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
  fi
  rm -rf "${FAKE:?}/proj" "${FAKE:?}/control-repo"
done

# 6. depth boundary (ledger ruling): a repo ROOT at depth 4 is found, at 5 is not
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/a/b/c/repo"
out=$(HOME="$FAKE" _discover_repos)
if [ "$out" = "a/b/c/repo" ]; then
  ok "repo root at depth 4 found (maxdepth reaches its .git at 5)"
else
  bad "depth 4 found" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/a/b/c/d/repo"
mkrepo "$FAKE/control-repo"
out=$(HOME="$FAKE" _discover_repos); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "control-repo" ]; then
  ok "repo root at depth 5 not found (documented depth limit, control found)"
else
  bad "depth 5 limit" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 7. spaces in repo paths survive intact
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/my repos/app one"
out=$(HOME="$FAKE" _discover_repos)
if [ "$out" = "my repos/app one" ]; then
  ok "space-named repo path intact"
else
  bad "space in path" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 8. a repo reached through a SYMLINK is not discovered (find does not follow
#    symlinks — loop risk); the real target still is
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/target"
ln -s "$FAKE/target" "$FAKE/link"
out=$(HOME="$FAKE" _discover_repos)
if [ "$out" = "target" ]; then
  ok "symlink to a repo not followed; real target found once"
else
  bad "symlink" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 9. $HOME itself holding .git is NOT recorded as a repo (that would overlay the
#    whole home); every other repo still is
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE"          # yes: the fake HOME itself is a repo
mkrepo "$FAKE/real"
out=$(HOME="$FAKE" _discover_repos)
if [ "$out" = "real" ]; then
  ok "\$HOME itself as a repo root is skipped"
else
  bad "HOME repo root" "got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 9b. a permission-denied subtree must not discard the rest of the walk:
#     find exits non-zero there, and partial results are the answer
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/findable"
mkdir -p "$FAKE/locked/sub"
mkrepo "$FAKE/locked/sub/hidden"
chmod 000 "$FAKE/locked"
out=$(HOME="$FAKE" _discover_repos); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "findable" ]; then
  ok "permission-denied subtree: walk continues, findable repo still found"
else
  bad "permission-denied subtree" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi
chmod 755 "$FAKE/locked"
rm -rf "$FAKE"

# 10. an empty HOME: empty output, rc 0, no crash
FAKE=$(mktemp -d); rm -rf "$FAKE"
out=$(HOME="$FAKE" _discover_repos); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "empty HOME: empty discovery, rc 0"
else
  bad "empty HOME" "rc=$rc got: $(printf '%s' "$out" | tr '\n' '|')"
fi
rm -rf "$FAKE"

# 11. _repo_remote: origin wins over other remotes
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/r" "https://example.com/origin.git"
git -C "$FAKE/r" remote add upstream "https://example.com/up.git" 2>/dev/null
out=$(_repo_remote "$FAKE/r")
if [ "$out" = "https://example.com/origin.git" ]; then
  ok "_repo_remote: origin preferred over other remotes"
else
  bad "_repo_remote origin" "got: $out"
fi
rm -rf "$FAKE"

# 12. _repo_remote: no origin -> the first remote
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/r"
git -C "$FAKE/r" remote add first "https://example.com/first.git" 2>/dev/null
out=$(_repo_remote "$FAKE/r")
if [ "$out" = "https://example.com/first.git" ]; then
  ok "_repo_remote: first remote as fallback"
else
  bad "_repo_remote fallback" "got: $out"
fi
rm -rf "$FAKE"

# 13. _repo_remote: no remote -> empty, rc 0
FAKE=$(mktemp -d); rm -rf "$FAKE"
mkrepo "$FAKE/r"
out=$(_repo_remote "$FAKE/r"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "_repo_remote: no remote -> empty output"
else
  bad "_repo_remote none" "rc=$rc got: $out"
fi
rm -rf "$FAKE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
