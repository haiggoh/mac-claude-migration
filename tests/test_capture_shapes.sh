#!/bin/bash
# Verify the capture mechanism survives the FILE-vs-DIRECTORY shape change.
#
# Real incident: ~/.api_keys went from a single sourceable file to a directory of
# one-secret-per-file. The rsync leg kept working (rsync -a is recursive) but the
# DOCS did not, and a `cp` without -r would have silently dropped it. These cases
# replay the actual copy against a fake HOME so a future refactor cannot regress
# it, and assert the 0600/0700 modes that make it safe to carry secrets.
#
# Usage: test_capture_shapes.sh [--help]
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd); ROOT=$(dirname "$HERE")
[ "${1:-}" = "--help" ] && { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
[ $# -gt 0 ] && { echo "unexpected argument: $1" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Mirror the excludes backup.sh uses, so this tests the real invocation shape.
EXCLUDES=(--no-specials --no-devices --exclude='**/.DS_Store' --exclude='**/.venv/'
          --exclude='**/venv/' --exclude='**/node_modules/' --exclude='**/__pycache__/')

FAKE=$(mktemp -d); DEST=$(mktemp -d)
trap 'rm -rf "$FAKE" "$DEST"' EXIT

# a DIRECTORY of secrets, as ~/.api_keys is today
mkdir -p "$FAKE/.api_keys"; chmod 700 "$FAKE/.api_keys"
for k in elevenlabs gemini cloudflare-account-id; do
  printf 'secret-value-for-%s' "$k" > "$FAKE/.api_keys/$k"; chmod 600 "$FAKE/.api_keys/$k"
done
# a plain FILE too, to prove the same leg handles both shapes
printf 'export FOO=bar\n' > "$FAKE/.zshrc"; chmod 644 "$FAKE/.zshrc"
# a nested dir, since secrets also live at .config/gh
mkdir -p "$FAKE/.config/gh"; printf 'token\n' > "$FAKE/.config/gh/hosts.yml"; chmod 600 "$FAKE/.config/gh/hosts.yml"

( cd "$FAKE" && rsync -aR "${EXCLUDES[@]}" .api_keys .zshrc .config/gh "$DEST/" ) 2>/dev/null

# every file must arrive
n=0; for k in elevenlabs gemini cloudflare-account-id; do [ -f "$DEST/.api_keys/$k" ] && n=$((n+1)); done
[ "$n" -eq 3 ] && ok "directory of secrets: all 3 files captured" \
              || bad "directory of secrets" "only $n/3 arrived -- a non-recursive copy would do this"
[ -f "$DEST/.zshrc" ] && ok "plain file captured by the same leg" || bad "plain file" "missing"
[ -f "$DEST/.config/gh/hosts.yml" ] && ok "nested secret dir captured" || bad "nested secret dir" "missing"

# modes must survive, or the archive leaks
m=$(stat -f '%Lp' "$DEST/.api_keys" 2>/dev/null || stat -c '%a' "$DEST/.api_keys")
[ "$m" = "700" ] && ok "secret DIR mode preserved (700)" || bad "secret dir mode" "got $m, want 700"
m=$(stat -f '%Lp' "$DEST/.api_keys/elevenlabs" 2>/dev/null || stat -c '%a' "$DEST/.api_keys/elevenlabs")
[ "$m" = "600" ] && ok "secret FILE mode preserved (600)" || bad "secret file mode" "got $m, want 600"

# content must be intact, not truncated
got=$(cat "$DEST/.api_keys/elevenlabs")
[ "$got" = "secret-value-for-elevenlabs" ] && ok "secret content intact" || bad "secret content" "got '$got'"

# the restore leg must round-trip modes too
BACK=$(mktemp -d); rsync -a --no-specials --no-devices "$DEST/" "$BACK/" 2>/dev/null
m=$(stat -f '%Lp' "$BACK/.api_keys/elevenlabs" 2>/dev/null || stat -c '%a' "$BACK/.api_keys/elevenlabs")
[ "$m" = "600" ] && ok "restore leg preserves 600" || bad "restore leg" "got $m, want 600"
rm -rf "$BACK"

# the scripts must not still DESCRIBE .api_keys as a single file
if grep -q 'api_keys.* is mode 600 and is the ONLY' "$ROOT/backup.sh" 2>/dev/null; then
  bad "backup.sh docs" "still calls .api_keys a single mode-600 file"
else ok "backup.sh docs do not call .api_keys a lone file"; fi
# NOTE: the stale claim spans TWO lines, so a line-based grep misses it -- that
# mistake let this very assertion pass against the buggy script. Match across
# newlines with tr, or the test is decorative.
if tr '\n' ' ' < "$ROOT/restore.sh" | grep -qE 'echo \$ELEVENLABS_API_KEY.{0,80}zshrc sources'; then
  bad "restore.sh docs" "verification step assumes ~/.zshrc sources ~/.api_keys"
else ok "restore.sh verification step does not assume sourcing"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
