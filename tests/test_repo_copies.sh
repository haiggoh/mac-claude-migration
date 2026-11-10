#!/bin/bash
# Whole-tree copies (`+` lines) in backup + restore (plan Task 5).
# backup: a `+` repo is archived under repo-copies/<safe>.tar.gz (safe = tr / __)
# with tracked + untracked files (gitignore-respected) PLUS its .git tree, minus
# the overlay's extra greps (.venv/venv/node_modules/__pycache__ even when
# tracked) and .DS_Store; its repos.tsv row carries an EMPTY URL.
# restore: an empty-URL row WITH a tarball extracts to $HOME/<path> (skipped
# with a message when the destination exists); an empty-URL row WITHOUT a
# tarball keeps today's "no remote — skipping" warning, which is what makes old
# archives restore unchanged. Real runs only against fake HOMEs; remotes are
# LOCAL PATHS (no network); brew/pipx stubbed.
#
# Usage: test_repo_copies.sh [--help]
set -u
export LC_ALL=C
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
SAVED_HOME="$HOME"; SAVED_PATH="$PATH"
STUB=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUB/brew";  chmod +x "$STUB/brew"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pipx";  chmod +x "$STUB/pipx"
FAKE=""; OUT=""; RH=""   # RH = restore-target fake HOME
cleanup() {
  [ -n "$FAKE" ] && rm -rf "$FAKE"
  [ -n "$OUT" ] && rm -rf "$OUT"
  [ -n "$RH" ] && rm -rf "$RH"
  rm -rf "$STUB"
  HOME="$SAVED_HOME"
}
trap cleanup EXIT

# --- fixture: fake HOME with a + no-remote repo, a space-named + repo, and a
# remote repo (pre-seeded list lines honour explicit user choices)
FAKE=$(mktemp -d); rm -rf "$FAKE"; mkdir -p "$FAKE"
OUT=$(mktemp -d); rm -rf "$OUT"; mkdir -p "$OUT"
ORIGIN=$(mktemp -d); rm -rf "$ORIGIN"
git init -q --bare "$ORIGIN/rem.git" 2>/dev/null
mkrepo() {  # mkrepo <abs-path> — init + one committed file
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  printf 'content\n' > "$1/seed.txt"
  git -C "$1" add seed.txt
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null
}
# proj: tracked + untracked + gitignored + tracked-inside-.venv
mkrepo "$FAKE/proj"
printf 'a\n' > "$FAKE/proj/a.txt";        git -C "$FAKE/proj" add a.txt
printf 'ign\n' > "$FAKE/proj/ignored.txt"
printf 'ignored.txt\n' > "$FAKE/proj/.gitignore"; git -C "$FAKE/proj" add .gitignore
git -C "$FAKE/proj" -c user.email=t@t -c user.name=t commit -q -m files 2>/dev/null
printf 'b\n' > "$FAKE/proj/b.txt"          # untracked, not ignored
mkdir -p "$FAKE/proj/.venv"; printf 'v\n' > "$FAKE/proj/.venv/t.py"
git -C "$FAKE/proj" add -f .venv/t.py      # tracked INSIDE .venv — must still be excluded
git -C "$FAKE/proj" -c user.email=t@t -c user.name=t commit -q -m venv 2>/dev/null
# space-named repo with a space-named file
mkrepo "$FAKE/my repos/app one"
printf 's\n' > "$FAKE/my repos/app one/my file.txt"
git -C "$FAKE/my repos/app one" add "my file.txt"
git -C "$FAKE/my repos/app one" -c user.email=t@t -c user.name=t commit -q -m s 2>/dev/null
# remote repo (record): pushed to a LOCAL bare origin (no network)
mkrepo "$FAKE/rem"
git -C "$FAKE/rem" remote add origin "$ORIGIN/rem.git"
git -C "$FAKE/rem" push -q origin HEAD 2>/dev/null
# explicit list: both + copies and the record line
printf '+proj\n+my repos/app one\nrem\n' > "$FAKE/.claude-migration-repos"

run_backup() {  # non-terminal, alarm-guarded, stubbed brew/pipx
  env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$FAKE" PATH="$STUB:$SAVED_PATH" \
    perl -e 'alarm 90; exec @ARGV' /bin/bash "$ROOT/backup.sh" "$OUT" </dev/null 2>&1
}
BACKUP_OUT="$(run_backup)"
arch=""
for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && arch="$a"; done
TSV=""; COPIES_TGZ=""; SPACE_TGZ=""
if [ -n "$arch" ]; then
  TSV="$(tar -xzOf "$arch" ./repos.tsv 2>/dev/null)"
  tar -xzf "$arch" -C "$OUT" "./repo-copies/proj.tar.gz" 2>/dev/null && COPIES_TGZ="$OUT/repo-copies/proj.tar.gz"
  # tr is 1:1: "my repos/app one" -> "my repos_app one" (one underscore — same
  # transform as the 0.1.x overlay naming, accepted edge)
  tar -xzf "$arch" -C "$OUT" "./repo-copies/my repos_app one.tar.gz" 2>/dev/null && SPACE_TGZ="$OUT/repo-copies/my repos_app one.tar.gz"
fi

# 1. backup: copy tarball exists with the right members
if [ -n "$COPIES_TGZ" ] \
   && tar -tzf "$COPIES_TGZ" | grep -Fx 'a.txt' \
   && tar -tzf "$COPIES_TGZ" | grep -Fx 'b.txt' \
   && tar -tzf "$COPIES_TGZ" | grep -Fx '.git/HEAD' \
   && tar -tzf "$COPIES_TGZ" | grep -Fx '.gitignore' \
   && ! tar -tzf "$COPIES_TGZ" | grep -Fx 'ignored.txt' \
   && ! tar -tzf "$COPIES_TGZ" | grep -Fx '.venv/t.py'; then
  ok "backup copy tarball: tracked + untracked + .git/HEAD; ignored and tracked-.venv excluded"
else
  bad "copy tarball" "tgz=${COPIES_TGZ:+yes} members=$(tar -tzf "$COPIES_TGZ" 2>/dev/null | tr '\n' '|')"
fi

# 2. backup: repos.tsv row for the copy has an EMPTY URL and a non-empty sha
#    (plain grep, NOT -F: -F makes ^ literal — the documented grep -F trap)
crow="$(printf '%s' "$TSV" | grep $'^proj\t')"
if printf '%s' "$crow" | grep -q $'^proj\t\t' \
   && [ "$(printf '%s' "$crow" | awk -F'\t' "{print \$NF}" | wc -c | tr -d ' ')" -gt 1 ]; then
  ok "repos.tsv copy row: empty URL field, sha present"
else
  bad "copy row" "row=$(printf '%s' "$crow" | tr '\t' '|')"
fi

# 3. backup: space-named repo survives intact (tarball name, inner paths)
if [ -n "$SPACE_TGZ" ] \
   && tar -tzf "$SPACE_TGZ" | grep -Fx 'my file.txt' \
   && mkdir -p "$OUT/space-x" \
   && tar -xzf "$SPACE_TGZ" -C "$OUT/space-x" \
   && [ -f "$OUT/space-x/my file.txt" ] && [ -f "$OUT/space-x/.git/HEAD" ]; then
  ok "space-named repo: tarball + extraction paths intact (my file.txt, .git/HEAD)"
else
  bad "space repo" "tgz=${SPACE_TGZ:+yes}"
fi

# 4. backup: remote repo still recorded normally (not copied)
rrow="$(printf '%s' "$TSV" | grep $'^rem\t')"
if printf '%s' "$rrow" | grep -q $'^rem\t'"$ORIGIN/rem.git" \
   && [ -z "$(printf '%s' "$TSV" | grep $'^rem\t' | awk -F'\t' '$2 == ""')" ]; then
  ok "remote repo: repos.tsv row keeps its URL (clone path unchanged)"
else
  bad "remote row" "row=$(printf '%s' "$rrow" | tr '\t' '|')"
fi

# 5. restore: + repo extracted WITH .git; remote repo cloned; both in a fresh fake HOME
RH=$(mktemp -d); rm -rf "$RH"; mkdir -p "$RH"
out=$(env -u MIGRATION_REPOS HOME="$RH" PATH="$STUB:$SAVED_PATH" \
      perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/restore.sh" "$arch" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] \
   && [ -f "$RH/proj/a.txt" ] && [ -f "$RH/proj/b.txt" ] && [ -f "$RH/proj/.git/HEAD" ] \
   && [ -d "$RH/proj/.git/objects" ] \
   && [ -d "$RH/rem/.git" ] && [ -f "$RH/rem/seed.txt" ] \
   && [ -f "$RH/my repos/app one/my file.txt" ] \
   && ! printf '%s' "$out" | grep -q 'no remote for proj'; then
  ok "restore: + repos extracted with .git, remote repo cloned, space paths intact"
else
  bad "restore" "rc=$rc proj-git=$([ -f "$RH/proj/.git/HEAD" ] && echo yes) rem=$([ -d "$RH/rem/.git" ] && echo yes) out=$(printf '%s' "$out" | tail -4 | tr '\n' '|')"
fi

# 6. restore twice: existing destination skipped with a message, content untouched
printf 'sentinel\n' > "$RH/proj/b.txt"
out2=$(env -u MIGRATION_REPOS HOME="$RH" PATH="$STUB:$SAVED_PATH" \
       perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/restore.sh" "$arch" </dev/null 2>&1); rc2=$?
if [ "$rc2" -eq 0 ] \
   && printf '%s' "$out2" | grep -q 'destination exists, skipping extraction: proj' \
   && [ "$(cat "$RH/proj/b.txt")" = "sentinel" ]; then
  ok "second restore: destination-exists skip message, user content untouched"
else
  bad "restore skip" "rc=$rc2 b.txt=$(cat "$RH/proj/b.txt" 2>/dev/null) out=$(printf '%s' "$out2" | grep -a 'proj' | head -2 | tr '\n' '|')"
fi

# 7. old-archive shape: empty-URL row WITHOUT a tarball keeps the old warning,
#    extracts nothing (this is what makes pre-0.2.0 archives restore unchanged)
OLD=$(mktemp -d); rm -rf "$OLD"
mkdir -p "$OLD/home" "$OLD/oldout"
printf 'SOURCE_USER=t\nSOURCE_HOME=%s\nTOOL_VERSION=0.1.5\n' "$FAKE" > "$OLD/meta.env"
printf 'proj\t\tmaster\tdeadbeef\nrem\t%s\tmaster\tdeadbeef\n' "$ORIGIN/rem.git" > "$OLD/repos.tsv"
cp "$FAKE/.claude-migration-repos" "$OLD/home/" 2>/dev/null || true
# explicit members: the tarball must not try to include itself
tar czf "$OLD/old.tar.gz" -C "$OLD" meta.env repos.tsv home
RH2=$(mktemp -d); rm -rf "$RH2"; mkdir -p "$RH2"
out3=$(env -u MIGRATION_REPOS HOME="$RH2" PATH="$STUB:$SAVED_PATH" \
       perl -e 'alarm 120; exec @ARGV' /bin/bash "$ROOT/restore.sh" "$OLD/old.tar.gz" </dev/null 2>&1); rc3=$?
if [ "$rc3" -eq 0 ] \
   && printf '%s' "$out3" | grep -q 'no remote for proj — skipping' \
   && [ ! -e "$RH2/proj" ]; then
  ok "old archive: empty-URL row without tarball keeps 'no remote — skipping', extracts nothing"
else
  bad "old archive" "rc=$rc3 out=$(printf '%s' "$out3" | grep -a 'remote\|proj' | head -3 | tr '\n' '|')"
fi
rm -rf "$RH2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
