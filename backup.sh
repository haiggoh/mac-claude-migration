#!/usr/bin/env bash
#
# 📦 backup.sh — capture the NON-redownloadable state of this Claude Code setup.
#
# Philosophy (per the migration plan):
#   • PACKAGE  = local-only state that cannot be fetched from anywhere else
#                (session transcripts, memory, settings, .claude.json project
#                 map, dotfiles, secrets, plugin *selection* manifest).
#   • REINSTALL = anything public: Homebrew formulae, git repos, virtualenvs,
#                 node_modules, pipx tools, plugin *payloads*, the Claude binary.
#                 We do NOT copy these; we record exactly which versions/commits
#                 you had so restore.sh reproduces them with zero gap.
#
# Output: ~/claude-migration/claude-migration-<stamp>.tar.gz  (chmod 600)
#         ⚠️ Contains secrets (SSH keys, API keys, gh token). Transfer over
#            AirDrop / USB / encrypted channel — never email or cloud paste.
#
# Usage: bash backup.sh            # writes into ~/claude-migration
#        bash backup.sh /some/dir  # writes into /some/dir
#
set -euo pipefail

# --- argument parsing MUST come before any work -------------------------------
# A user probing an unfamiliar script with --help expects to be told something,
# not to trigger a backup that writes a tarball full of secrets.
usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  printf 'Options:\n  -h, --help   show this help and exit\n  --dry-run    print what would be captured, then exit without writing\n'
}
DRY_RUN=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --dry-run) DRY_RUN=1; shift;;
    -*) printf '%s: unknown option: %s\n' "${0##*/}" "$1" >&2
        printf 'Try `%s --help`.\n' "${0##*/}" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done
if [ "${#ARGS[@]}" -gt 1 ]; then
  printf '%s: expected at most one output directory, got %d\n' "${0##*/}" "${#ARGS[@]}" >&2
  exit 2
fi
set -- "${ARGS[@]+"${ARGS[@]}"}"

SRC="$HOME"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/claude-migration}"
STAGE="$OUT/stage-$STAMP"
HOMEDIR="$STAGE/home"          # mirrors a subset of $HOME
ARCHIVE="$OUT/claude-migration-$STAMP.tar.gz"

if [ "$DRY_RUN" = 1 ]; then
  printf 'DRY RUN — nothing will be written.\n\n'
  printf 'Would write archive: %s\n' "$ARCHIVE"
  printf 'Would stage under:   %s\n\n' "$STAGE"
  printf 'Paths that exist and would be captured:\n'
  for rel in .claude .claude.json .claude-flow .joyia .zshrc .zshrc.backup \
             .gitconfig .zsh_history .ssh .api_keys .config/gh .config/corridorkey \
             .config/iterm2 .docker/config.json; do
    if [ -e "$SRC/$rel" ]; then
      if [ -d "$SRC/$rel" ]; then printf '  dir   %s/\n' "$rel"; else printf '  file  %s\n' "$rel"; fi
    else
      printf '  ABSENT %s\n' "$rel"
    fi
  done
  printf '\nRun without --dry-run to create the archive.\n'
  exit 0
fi

mkdir -p "$HOMEDIR" "$STAGE/repo-overlays"

log() { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

# rsync helper: copy path (relative to $HOME) into stage, preserving structure,
# symlinks (-a keeps them AS symlinks), and applying shared excludes.
COMMON_EXCLUDES=(
  --no-specials --no-devices          # skip sockets/pipes (e.g. SSH control sockets)
  --exclude='**/.DS_Store'
  --exclude='**/.venv/'
  --exclude='**/venv/'
  --exclude='**/node_modules/'
  --exclude='**/__pycache__/'
)
copy_rel() {  # copy_rel <relpath> [extra rsync args...]  — run from within $SRC
  local rel="$1"; shift
  [ -e "$SRC/$rel" ] || { warn "skip (missing): $rel"; return 0; }
  ( cd "$SRC" && rsync -aR "${COMMON_EXCLUDES[@]}" "$@" "$rel" "$HOMEDIR/" )
}

########################################################################
log "1/6  Claude Code state (.claude, minus redownloadable payloads/caches)"
########################################################################
# Keep everything in .claude EXCEPT plugin payloads/caches and pure runtime junk.
# We KEEP plugins/{installed_plugins,known_marketplaces}.json — the tiny manifest
# that tells restore.sh which marketplaces + plugins to reinstall.
( cd "$SRC" && rsync -aR "${COMMON_EXCLUDES[@]}" \
  --exclude='.claude/plugins/cache/' \
  --exclude='.claude/plugins/marketplaces/' \
  --exclude='.claude/plugins/plugin-catalog-cache.json' \
  --exclude='.claude/cache/' \
  --exclude='.claude/shell-snapshots/' \
  --exclude='.claude/daemon.lock' \
  --exclude='.claude/daemon.log' \
  --exclude='.claude/daemon.status.json' \
  --exclude='.claude/mcp-needs-auth-cache.json' \
  --exclude='.claude/stats-cache.json' \
  .claude "$HOMEDIR/" )
# NOTE: .claude/skills/video-use is a symlink -> ClaudeWorkspace/video-use.
# rsync -a preserves it as a symlink; it resolves on restore because the
# username (and therefore the target path) is identical on the new Mac.

########################################################################
log "2/6  Top-level config, project map & shell state"
########################################################################
copy_rel ".claude.json"
for f in "$SRC"/.claude.json.bak*; do
  [ -e "$f" ] && ( cd "$SRC" && rsync -aR --no-specials --no-devices "$(basename "$f")" "$HOMEDIR/" )
done
copy_rel ".claude-flow"
copy_rel ".joyia"                 # kept for reference; fresh joyia setup may overwrite
copy_rel ".zshrc"
copy_rel ".zshrc.backup"
copy_rel ".gitconfig"
copy_rel ".zsh_history"
copy_rel "ClaudeWorkspace/claude-mcp-setup.md"

########################################################################
log "3/6  Secrets & credentials (⚠️ sensitive)"
########################################################################
copy_rel ".ssh"
copy_rel ".api_keys"              # DIRECTORY: one bare-value secret per file (mode 600),
                                  # loaded by the ~/.zshrc filename->env-var loop.
                                  # rsync -a is recursive, so the whole dir comes along.
copy_rel ".config/gh"             # GitHub PAT / gh CLI auth
copy_rel ".config/corridorkey"
copy_rel ".config/iterm2"
copy_rel ".docker/config.json"
# Hugging Face login token, IF you're logged in (targeted files only — NOT the
# multi-GB ~/.cache/huggingface/hub model cache, which is public/redownloadable).
# Absent today; captured automatically if you `hf auth login` before migrating.
hf_found=0
for t in ".cache/huggingface/token" ".cache/huggingface/stored_tokens" ".huggingface/token"; do
  [ -e "$SRC/$t" ] && { copy_rel "$t"; hf_found=1; }
done
[ "$hf_found" = 0 ] && warn "no Hugging Face token found (not logged in) — nothing to capture; hub models are public/redownloadable"
# gcloud (86M, mostly a venv) is re-authenticated, not copied — see MANIFEST.md.

########################################################################
log "4/6  Git repos → record remote + exact commit + uncommitted overlay"
########################################################################
# These are all public. restore.sh clones them, checks out the RECORDED SHA
# (so you land on the same commit, not upstream HEAD), then applies an overlay
# of your uncommitted/untracked files (respecting .gitignore, so venvs are
# excluded automatically). This is "download from public source + zero gap".
REPOS=(
  "ClaudeWorkspace/measure-twice"
  "ClaudeWorkspace/claude-code-desktop-sync"
  "ClaudeWorkspace/video-use"
  "ClaudeWorkspace/no-hidden-changes"
  "mcp-servers/adobe-mcp"
)
: > "$STAGE/repos.tsv"   # path<TAB>url<TAB>branch<TAB>sha
for rel in "${REPOS[@]}"; do
  d="$SRC/$rel"
  [ -d "$d/.git" ] || { warn "not a git repo, skipping repo-mode: $rel"; continue; }
  url="$(git -C "$d" remote get-url origin 2>/dev/null || echo '')"
  sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '')"
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"
  printf '%s\t%s\t%s\t%s\n' "$rel" "$url" "$branch" "$sha" >> "$STAGE/repos.tsv"
  # overlay = modified + untracked, gitignore-respected (excludes .venv etc.)
  safe="$(echo "$rel" | tr '/' '__')"
  ( cd "$d"
    git ls-files -m -o --exclude-standard \
      | grep -vE '(^|/)(\.venv|venv|node_modules|__pycache__)/' \
      | grep -vE '(^|/)\.DS_Store$' > "$STAGE/repo-overlays/$safe.filelist" || true
    if [ -s "$STAGE/repo-overlays/$safe.filelist" ]; then
      tar czf "$STAGE/repo-overlays/$safe.tar.gz" -T "$STAGE/repo-overlays/$safe.filelist"
      echo "    overlay: $rel ($(wc -l < "$STAGE/repo-overlays/$safe.filelist" | tr -d ' ') file(s))"
    fi )
  # Warn about unpushed commits — those are NOT on the remote, so cloning misses them.
  unpushed="$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
  [ "$unpushed" != "0" ] && warn "  $rel has $unpushed UNPUSHED commit(s) — push them before migrating!"
done

########################################################################
log "5/6  Reinstall manifests (public toolchain — recorded, not packaged)"
########################################################################
if command -v brew >/dev/null 2>&1; then
  brew bundle dump --file="$STAGE/Brewfile" --force >/dev/null 2>&1 \
    && echo "    Brewfile: $(grep -c . "$STAGE/Brewfile") entries" \
    || warn "brew bundle dump failed"
fi
command -v pipx >/dev/null 2>&1 && pipx list --short > "$STAGE/pipx-list.txt" 2>/dev/null || true
cp "$SRC/.claude/plugins/installed_plugins.json"  "$STAGE/" 2>/dev/null || true
cp "$SRC/.claude/plugins/known_marketplaces.json" "$STAGE/" 2>/dev/null || true
# Pin the Claude Code version you're on right now.
if [ -L "$SRC/.local/bin/claude" ]; then
  basename "$(readlink "$SRC/.local/bin/claude")" > "$STAGE/claude-version.txt"
fi

########################################################################
log "6/6  Write MANIFEST.md and pack the archive"
########################################################################
cat > "$STAGE/MANIFEST.md" <<'MD'
# Claude Code migration archive

Generated by backup.sh. Restore with `restore.sh` on the new Mac (same username
`bra0002h` assumed). Contains local-only STATE; public payloads are reinstalled.

## What's inside (packaged state)
- `home/.claude/`          — settings, memory, session transcripts, plans, tasks,
                             file-history, agents, commands, skills, telemetry,
                             desktop-sync, scripts, joyia-statusline.sh, and the
                             plugin *manifest* (installed_plugins/known_marketplaces).
                             Plugin PAYLOADS + caches were excluded (reinstalled).
- `home/.claude.json` + .bak*  — project map, MCP servers, favorite plugins.
- `home/.joyia/`           — gateway config (reference; fresh joyia may overwrite).
- `home/.zshrc`, `.zshrc.backup`, `.gitconfig`, `.zsh_history`, `.claude-flow`.
- `home/.ssh/`, `home/.api_keys/`, `home/.config/{gh,corridorkey,iterm2}`,
  `home/.docker/config.json` — SECRETS. (`.api_keys` is a DIRECTORY, mode 700,
  holding one bare-value secret per file at mode 600 — ElevenLabs, Gemini, Groq,
  OpenRouter, Cloudflare + account id, Cerebras, NVIDIA. It is the ONLY copy of
  all of them. rsync -a is recursive and preserves modes both ways — verified
  2026-09-14 by replaying the real rsync leg.)
- `repos.tsv` + `repo-overlays/` — git repos: exact remote+commit, plus your
                             uncommitted/untracked files to re-apply after clone.
- `Brewfile`, `pipx-list.txt`, `claude-version.txt`, plugin manifests — reinstall inputs.

## Reinstalled by restore.sh (NOT packaged — public sources)
- Homebrew formulae/casks (from Brewfile) incl. ffmpeg, yt-dlp, uv, node, gh, python.
- Claude Code binary (fresh install; version pin in claude-version.txt).
- Claude plugins + marketplaces (payloads re-fetched from manifest).
- Git repos (clone + checkout recorded SHA + overlay): measure-twice,
  claude-code-desktop-sync, video-use, no-hidden-changes, adobe-mcp.
- Virtualenvs (uv sync) and node_modules (npm install) for video-use & adobe-mcp.
- pipx tools (litellm).

## Manual re-auth after restore (credentials that live in a keychain/token, not files)
- `gh auth login`         (if the copied gh config isn't accepted)
- `gcloud auth login`     (gcloud config not copied — 86M venv)
- Hugging Face: only if a token was captured (see backup log). If not, you were
  never logged in — `hf` works anonymously for public repos; run `hf auth login`
  only if you later need private/gated access.
- joyia gateway: run your fresh joyia setup as planned.
MD

log "Packing → $ARCHIVE"
tar czf "$ARCHIVE" -C "$STAGE" .
chmod 600 "$ARCHIVE"
rm -rf "$STAGE"

SIZE="$(du -sh "$ARCHIVE" | cut -f1)"
echo
log "DONE. Archive: $ARCHIVE  ($SIZE)"
warn "This archive contains SECRETS. Move it to the new Mac over AirDrop/USB, not cloud."
echo "Next: copy restore.sh + this archive to the new Mac, then run:"
echo "    bash restore.sh \"$ARCHIVE\""
