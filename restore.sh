#!/usr/bin/env bash
#
# 📦 restore.sh — rebuild the Claude Code setup on the NEW Mac from an archive
#              produced by backup.sh. Assumes the same username (bra0002h),
#              so all absolute-path symlinks resolve unchanged.
#
# Order matters:
#   1. Homebrew toolchain (git, uv, node, ffmpeg, yt-dlp, gh, python, pipx…)
#   2. Restore packaged state into $HOME (existing files backed up first)
#   3. Clone git repos → checkout recorded SHA → apply uncommitted overlay
#   4. Recreate virtualenvs / node_modules (uv sync, npm install)
#   5. pipx tools
#   6. Claude Code binary + plugins (fresh install; plugins re-fetch from manifest)
#   7. Print remaining manual steps (joyia, re-auth)
#
# Usage: bash restore.sh /path/to/claude-migration-<stamp>.tar.gz
#
set -euo pipefail

# --- argument parsing MUST come before any work -------------------------------
# Without this, `restore.sh --help` was read as an ARCHIVE FILENAME: it printed
# "archive not found: --help" and exited 0, so a failed probe looked like a
# successful one.
usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  printf 'Options:\n  -h, --help   show this help and exit\n'
}
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    -*) printf '%s: unknown option: %s\n' "${0##*/}" "$1" >&2
        printf 'Try `%s --help`.\n' "${0##*/}" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ $# -ne 1 ]; then
  printf '%s: expected exactly one archive path\n' "${0##*/}" >&2
  printf 'Try `%s --help`.\n' "${0##*/}" >&2
  exit 2
fi
ARCHIVE="$1"
[ -f "$ARCHIVE" ] || { echo "archive not found: $ARCHIVE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BKP="$HOME/.migration-preexisting-$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

log "Unpacking archive → $TMP"
tar xzf "$ARCHIVE" -C "$TMP"
STAGE="$TMP"                      # backup.sh tarred the stage dir contents at root
[ -d "$STAGE/home" ] || { echo "malformed archive: no home/ dir" >&2; exit 1; }

########################################################################
log "1/7  Homebrew toolchain"
########################################################################
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not installed. Install it first:"
  echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  echo "  then re-run this script."
  exit 1
fi
if [ -f "$STAGE/Brewfile" ]; then
  brew bundle --file="$STAGE/Brewfile" || warn "some brew entries failed — review above"
  ok "Homebrew formulae restored"
else
  warn "no Brewfile in archive — ensure git, uv, node, ffmpeg, yt-dlp, gh are installed"
fi

########################################################################
log "2/7  Restore packaged state into \$HOME (pre-existing files backed up)"
########################################################################
# Back up anything we're about to overwrite, so the fresh install isn't lost.
mkdir -p "$BKP"
while IFS= read -r -d '' f; do
  rel="${f#"$STAGE/home/"}"
  if [ -e "$HOME/$rel" ] && [ ! -d "$HOME/$rel" ]; then
    mkdir -p "$BKP/$(dirname "$rel")"; cp -a "$HOME/$rel" "$BKP/$rel" 2>/dev/null || true
  fi
done < <(find "$STAGE/home" -type f -print0)
# Merge state in (-a preserves the video-use symlink; won't delete new-machine files).
# NOTE: .joyia/ is excluded on purpose — keep the freshly-configured joyia setup
#       (API key etc.) on THIS machine; the archived joyia state is stale.
rsync -a --no-specials --no-devices --exclude='.joyia/' "$STAGE/home/" "$HOME/"
ok "State restored. (Overwritten originals saved in $BKP)"
warn "Skipped ~/.joyia/ — your existing joyia config was left untouched."

########################################################################
log "3/7  Clone git repos → exact commit → apply overlay"
########################################################################
if [ -f "$STAGE/repos.tsv" ]; then
  while IFS=$'\t' read -r rel url branch sha; do
    [ -n "$url" ] || { warn "no remote for $rel — skipping"; continue; }
    dest="$HOME/$rel"
    if [ -d "$dest/.git" ]; then
      ok "exists, skipping clone: $rel"
    else
      mkdir -p "$(dirname "$dest")"
      log "clone $url → $rel"
      git clone "$url" "$dest"
      if [ -n "$sha" ]; then
        git -C "$dest" checkout --quiet "$sha" 2>/dev/null \
          && ok "checked out $sha" \
          || warn "could not checkout $sha (remote may have diverged) — on $branch HEAD"
      fi
    fi
    # re-apply your uncommitted/untracked overlay
    safe="$(echo "$rel" | tr '/' '__')"
    if [ -f "$STAGE/repo-overlays/$safe.tar.gz" ]; then
      tar xzf "$STAGE/repo-overlays/$safe.tar.gz" -C "$dest"
      ok "overlay applied: $rel"
    fi
  done < "$STAGE/repos.tsv"
fi

########################################################################
log "4/7  Recreate virtualenvs & node_modules"
########################################################################
if command -v uv >/dev/null 2>&1; then
  for r in "$HOME/ClaudeWorkspace/video-use" "$HOME/mcp-servers/adobe-mcp"; do
    if [ -f "$r/uv.lock" ] || [ -f "$r/pyproject.toml" ]; then
      log "uv sync → $r"; ( cd "$r" && uv sync ) || warn "uv sync failed in $r"
    fi
  done
else
  warn "uv not found — install via brew, then run 'uv sync' in video-use & adobe-mcp"
fi
# adobe-mcp proxy-server node deps
if [ -f "$HOME/mcp-servers/adobe-mcp/proxy-server/package.json" ]; then
  log "npm install → adobe-mcp/proxy-server"
  ( cd "$HOME/mcp-servers/adobe-mcp/proxy-server" && npm install ) || warn "npm install failed"
fi

########################################################################
log "5/7  pipx tools"
########################################################################
if command -v pipx >/dev/null 2>&1 && [ -f "$STAGE/pipx-list.txt" ]; then
  # your setup had: litellm
  grep -qi litellm "$STAGE/pipx-list.txt" && { pipx install litellm || warn "pipx litellm failed"; }
else
  warn "pipx not found or no list — 'brew install pipx && pipx install litellm' if you need it"
fi

########################################################################
log "6/7  Claude Code + plugins"
########################################################################
if ! command -v claude >/dev/null 2>&1; then
  warn "Claude Code not installed. Install per your usual method (fresh install)."
  [ -f "$STAGE/claude-version.txt" ] && echo "    Old machine was on version: $(cat "$STAGE/claude-version.txt")"
else
  ok "claude present: $(claude --version 2>/dev/null || echo '?')"
fi
echo "  Plugin manifest restored to ~/.claude/plugins/ (installed_plugins.json,"
echo "  known_marketplaces.json). On first launch, open Claude Code and run:"
echo "      /plugin        # re-add marketplaces & reinstall the recorded plugin set"
echo "  (payloads re-fetch from their public marketplaces; nothing to copy)."

########################################################################
log "7/7  Manual steps that need a human (credentials in keychains/tokens)"
########################################################################
cat <<'STEPS'
  • joyia gateway : run your fresh joyia setup as planned.
  • gh auth       : if git push over HTTPS prompts, run  gh auth login
  • gcloud        : gcloud auth login        (config was not copied)
  • Hugging Face  : token restored automatically IF one was captured. If not,
                    you weren't logged in — `hf` works anonymously for public
                    repos; run `hf auth login` only for private/gated access.
  • Verify the API keys survived:   ls -l ~/.api_keys/   (a DIRECTORY, mode 700,
                    one bare-value secret per file at mode 600). ~/.zshrc turns each
                    filename into an env var (elevenlabs -> ELEVENLABS_API_KEY), so in
                    a NEW terminal: echo ${ELEVENLABS_API_KEY:+set}  ->  should print "set".
                    Do NOT expect ~/.zshrc to `source` these files — they hold a raw
                    secret, not shell syntax.
  • Open a new terminal so ~/.zshrc is sourced, then launch `claude`.
STEPS

ok "Restore complete. Review $BKP for any pre-existing files that were replaced."
