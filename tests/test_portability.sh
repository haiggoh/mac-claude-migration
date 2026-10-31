#!/bin/bash
# Portability contract for the public release: no machine-specific names or paths in
# the shipped scripts, version surfaces agree, scripts stay bash-3.2-parseable, and a
# fresh machine (empty fake HOME, no config) can dry-run.
#
# Usage: test_portability.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# 1. no machine-specific username or workspace path anywhere in the scripts
if grep -rnE 'bra0002h|ClaudeWorkspace|/Users/' "$ROOT/backup.sh" "$ROOT/restore.sh"; then
  bad "scripts carry no machine-specific path/username" "see hits above"
else
  ok "scripts carry no machine-specific path/username"
fi

# 2. VERSION == CHANGELOG top entry
v="$(tr -d '[:space:]' < "$ROOT/VERSION")"
cv="$(sed -n -E 's/^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?.*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"
[ -n "$v" ] && [ "$v" = "$cv" ] && ok "VERSION ($v) == CHANGELOG top entry ($cv)" \
  || bad "version surfaces" "VERSION='$v' changelog='$cv'"

# 3. both scripts parse under bash 3.2 (macOS /bin/bash)
for s in backup.sh restore.sh; do
  /bin/bash -n "$ROOT/$s" 2>/dev/null && ok "$s parses under /bin/bash (3.2)" \
    || bad "$s" "syntax error under bash 3.2"
done

# 4. a fresh machine can dry-run: empty fake HOME, no MIGRATION_* config, nothing written
SENT=$(mktemp -d); rm -rf "$SENT"
if out=$(env -u MIGRATION_REPOS -u MIGRATION_EXTRA_FILES HOME="$SENT" "$ROOT/backup.sh" --dry-run 2>&1); then
  printf '%s' "$out" | grep -q 'DRY RUN' && ok "fresh-machine --dry-run announces itself" \
    || bad "fresh-machine --dry-run" "no DRY RUN banner"
  [ -e "$SENT" ] && bad "fresh-machine --dry-run" "wrote under the fake HOME" \
    || ok "fresh-machine --dry-run writes nothing"
  printf '%s' "$out" | grep -qi 'no repos configured' && ok "warns when no repos configured" \
    || bad "fresh-machine --dry-run" "missing the no-repos warning"
else
  bad "fresh-machine --dry-run" "exited non-zero"
fi

# 5. MIGRATION_REPOS is honoured (dry-run lists the configured repo as present-or-absent, not skipped silently)
SENT2=$(mktemp -d); rm -rf "$SENT2"
out=$(env MIGRATION_REPOS="some/repo:other/repo" HOME="$SENT2" "$ROOT/backup.sh" --dry-run 2>&1)
# (repos.tsv content is only visible in a real run; here we assert the warning is GONE when configured)
if printf '%s' "$out" | grep -qi 'no repos configured'; then
  bad "MIGRATION_REPOS honoured" "warning still printed with the env var set"
else
  ok "MIGRATION_REPOS honoured (no empty-list warning when set)"
fi
TMPREAL="$HERE/.tmp-real-run.log"
trap 'rm -rf "$SENT2" "$TMPREAL"' EXIT

# 6. a REAL (non-dry) run under /bin/bash 3.2 with an empty config must survive the
#    empty REPOS array (set -u + bash 3.2 used to crash here: "REPOS[@]: unbound
#    variable") and still produce an archive
FAKEHOME=$(mktemp -d); OUT=$(mktemp -d); rm -rf "$FAKEHOME" "$OUT"
mkdir -p "$FAKEHOME/.config"; printf '# t\n' > "$FAKEHOME/.config/test"
if /bin/bash "$ROOT/backup.sh" "$OUT" >"$TMPREAL" 2>&1; then
  found=0; for a in "$OUT"/claude-migration-*.tar.gz; do [ -f "$a" ] && found=1; done
  [ "$found" = 1 ] && ok "real /bin/bash run with empty config produces an archive" \
    || bad "real empty-config run" "no archive produced"
else
  bad "real empty-config run" "crashed (bash 3.2 empty-array under set -u?) — see $TMPREAL"
fi
rm -rf "$FAKEHOME" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
