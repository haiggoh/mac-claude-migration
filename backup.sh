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
# Per-machine configuration (this script is machine-agnostic; configure yours):
#   MIGRATION_REPOS="projects/foo:servers/bar"   git repos to record
#       (remote + exact SHA + uncommitted overlay), colon-separated, relative
#       to $HOME — or one per line in ~/.claude-migration-repos
#   MIGRATION_EXTRA_FILES="projects/notes.md"        extra files to capture,
#       same syntax — or one per line in ~/.claude-migration-extra-files
#   Unset = no repos/extra files recorded (warned below): a fresh machine decides
#   what to carry. The source user/home are recorded in meta.env so restore.sh
#   can rewrite absolute-path symlinks on a machine with a different username.
#
# Usage: bash backup.sh            # interactive on a terminal: destination menu,
#                                  # archive built in the primary, copied to the rest;
#                                  # piped/scripted: writes into ~/claude-migration
#        bash backup.sh /some/dir  # writes into /some/dir (menu stays shut)
#        bash backup.sh --list-destinations
#                                  # print candidate destinations (path<TAB>label), exit
#
set -euo pipefail

# --- argument parsing MUST come before any work -------------------------------
# A user probing an unfamiliar script with --help expects to be told something,
# not to trigger a backup that writes a tarball full of secrets.
usage() {
  # print the whole header comment block, whatever its length (a fixed range once hid
  # every line added past it — measured on rtc-ship 0.6.11)
  awk 'NR==1 {next} !/^#/ {exit} {line=$0; sub(/^# ?/, "", line); if (line == "" && !started) next; started=1; print line}' "$0"
  printf 'Options:\n  -h, --help   show this help and exit\n  --dry-run    print what would be captured, then exit without writing\n  --list-destinations\n               print candidate destinations (path<TAB>label, default first) and exit\n'
}
DRY_RUN=0
LIST_DESTS=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --dry-run) DRY_RUN=1; shift;;
    --list-destinations) LIST_DESTS=1; shift;;
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

# --- destination detection (--list-destinations) -------------------------------
# Candidates for the destination-selection menu, one "path<TAB>label" line each:
# the default output directory FIRST, then every existing direct child of
# ~/Library/CloudStorage/ (label = directory name), then the legacy dirs
# ~/Dropbox and ~/OneDrive, then iCloud Drive. Existing directories only (the
# default is ALWAYS listed — the archive is built there, it may not exist yet),
# deduped by RESOLVED path so a CloudStorage root that is ~/Dropbox via a symlink
# is listed once. bash-3.2 pure: the dedupe set is a newline-delimited string,
# not an associative array.
_dest_emit() {  # _dest_emit <path> <label> — print unless already seen (resolved)
  local r needle
  r=$( cd -- "$1" 2>/dev/null && pwd -P ) || r="$1"
  # The seen-set is a case PATTERN; the needle is expanded INSIDE one continuous double
  # quote so the match is LITERAL — a path containing [ * ? must never act as a pattern
  # (bash already matches case-pattern expansions literally, but this states it and keeps
  # it POSIX-portable; pinned by tests/test_destinations.sh case 7).
  needle="
$r
"
  case "$_DEST_SEEN" in
    *"$needle"*) return 0 ;;
  esac
  _DEST_SEEN="$_DEST_SEEN
$r
"
  printf '%s\t%s\n' "$1" "$2"
}
_candidate_destinations() {
  local _d
  _DEST_SEEN=""
  _dest_emit "$1" 'Default — this is where the archive is built'
  if [ -d "$HOME/Library/CloudStorage" ]; then
    for _d in "$HOME/Library/CloudStorage/"*; do
      [ -d "$_d" ] || continue       # skips plain files AND broken symlinks
      _dest_emit "$_d" "${_d##*/}"
    done
  fi
  for _d in "$HOME/Dropbox" "$HOME/OneDrive"; do
    [ -d "$_d" ] || continue
    _dest_emit "$_d" "${_d##*/}"
  done
  if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
    _dest_emit "$HOME/Library/Mobile Documents/com~apple~CloudDocs" 'iCloud Drive'
  fi
  return 0
}

# --- interactive destination menu ----------------------------------------------
# Opens only when there is no positional OUT and both streams are terminals; piped,
# scripted, hook and explicit-arg runs take exactly the old path. The archive is always
# BUILT in the primary (first picked) destination; Task 3 copies it to the rest.
# Grammar: Enter/d = default; "1 3" or "1,3" = several (first = primary); a = every
# listed candidate (default included — it is entry 1); c = custom directory (a missing
# one needs a [y/N] confirm; --dry-run only announces it); q or EOF = abort, exit 1.
# bash-3.2 pure: indexed arrays only, no ${var,,}, expansions quoted except where
# tokenizing is the point (the answer line after comma->space normalization).
_choose_destinations() {  # _choose_destinations <default-out> — prints DESTS, primary first; abort exits 1
  local default_out="$1" lines line p l ans tok tok2 yn dir i n okp newp needle out rule
  local -a cpath=() clabel=()
  rule="$(printf '%72s' '')"; rule="${rule// /=}"
  lines="$(_candidate_destinations "$default_out")"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    p="${line%%$'\t'*}"
    l="${line#*$'\t'}"
    cpath+=("$p")
    clabel+=("$l")
  done <<< "$lines"
  n="${#cpath[@]}"

  local picked=""    # newline-separated picked entry indexes (pick order), or c:<path>
  # All menu chrome goes to STDERR: the caller captures only stdout (the DESTS list),
  # so the menu renders on the terminal while the picked paths travel in the variable.
  while true; do
    printf '\n📦 Mac Claude Migration\n' >&2
    printf '   Where should this backup go? Pick one, several, or a custom folder\n' >&2
    printf '%s\n\n' "$rule" >&2
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '  %d) %s\n     %s\n' "$((i + 1))" "${clabel[$i]}" "${cpath[$i]}" >&2
      i=$((i + 1))
    done
    printf '\n' >&2
    printf '  Enter = default only    numbers = pick several (e.g. 1 3 or 1,3)    a = all detected\n' >&2
    printf '  c = custom directory    q = abort the backup\n\n' >&2
    read -r ans || ans="q"          # EOF at the prompt aborts like q — never spin on a closed pipe
    ans="${ans//[,,]/ }"            # comma form of the number grammar
    case "$ans" in
      ""|d|D) picked="1"; break ;;
      q|Q) warn "backup aborted — nothing was written" >&2; exit 1 ;;
      a|A)
        i=1; picked=""
        while [ "$i" -le "$n" ]; do picked="$picked${picked:+$'\n'}$i"; i=$((i + 1)); done
        break ;;
      c|C)
        printf '  custom directory: ' >&2
        read -r dir || { warn "backup aborted — nothing was written" >&2; exit 1; }
        while [ "${dir%/}" != "$dir" ] && [ "$dir" != "/" ]; do dir="${dir%/}"; done
        # The "~/" pattern must match a LITERAL tilde in the user's input (that is the
        # point of the branch); $HOME would never match it.
        # shellcheck disable=SC2088
        case "$dir" in                  # ~ expands against HOME; never a literal "~" dir
          "~") dir="$HOME" ;;
          "~/"*) dir="$HOME/${dir:2}" ;;  # ${dir:2} strips "~/" — a #~/ pattern would tilde-expand
        esac
        if [ -z "$dir" ]; then continue; fi   # bare Enter at the custom prompt: re-ask
        if [ -d "$dir" ]; then picked="c:$dir"; break; fi
        printf '%s does not exist. Create it? [y/N] ' "$dir" >&2
        read -r yn || { warn "backup aborted — nothing was written" >&2; exit 1; }
        case "$yn" in
          y|Y|yes|YES)
            if [ "$DRY_RUN" = 1 ]; then
              printf '(dry run: would create %s)\n' "$dir" >&2
            else
              mkdir -p -- "$dir" || exit 1
            fi
            picked="c:$dir"; break ;;
        esac
        ;;                              # declined — re-render the menu
      *)
        okp=1; newp=""
        set -f                        # tokenizing is the point; an answer of "*" must not glob
        for tok in $ans; do
          case "$tok" in
            ''|*[!0-9]*) okp=0; break ;;
            ??????*) okp=0; break ;;  # >=6 digits: no menu has that many entries, and a
          esac                         # 20-digit token makes `[` error rc 2 and fall
          if [ "$tok" -lt 1 ] || [ "$tok" -gt "$n" ]; then okp=0; break; fi
          needle="$(printf '\n%s\n' "$tok")"
          case "
$newp
" in *"$needle"*) : ;; *) newp="${newp}${newp:+$'\n'}${tok}" ;; esac
        done
        set +f
        if [ "$okp" = 1 ] && [ -n "$newp" ]; then picked="$newp"; break; fi
        printf '  Unrecognized selection: %s\n\n' "$ans" >&2
        ;;
    esac
  done

  out=""
  while IFS= read -r tok2; do
    [ -z "$tok2" ] && continue
    case "$tok2" in
      c:*) out="${out}${out:+$'\n'}${tok2#c:}" ;;
      *)   out="${out}${out:+$'\n'}${cpath[$((tok2 - 1))]}" ;;
    esac
  done <<< "$picked"
  printf '%s\n' "$out"
  return 0
}

# --list-destinations is a probe, like --dry-run: print the candidates and exit
# BEFORE any work — no config parsing, no staging, nothing written.
if [ "$LIST_DESTS" = 1 ]; then
  _candidate_destinations "${1:-$HOME/claude-migration}"
  exit 0
fi

SRC="$HOME"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/claude-migration}"
STAGE="$OUT/stage-$STAMP"
HOMEDIR="$STAGE/home"          # mirrors a subset of $HOME
ARCHIVE="$OUT/claude-migration-$STAMP.tar.gz"

log() { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

# --- destination menu gate -------------------------------------------------------
# No positional OUT AND both streams a terminal -> the interactive selector. The
# archive is built in the primary (first picked) destination; DESTS carries the full
# chosen set for Task 3's copies. Everything else (pipe, script, hook, explicit arg)
# takes exactly the pre-menu path.
DESTS="$OUT"
if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  DESTS="$(_choose_destinations "$OUT")" || exit 1
  OUT="${DESTS%%$'\n'*}"
  STAGE="$OUT/stage-$STAMP"
  HOMEDIR="$STAGE/home"
  ARCHIVE="$OUT/claude-migration-$STAMP.tar.gz"
  printf 'Destinations: '
  _first=1
  while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    if [ "$_first" -eq 1 ]; then printf '%s (primary)' "$_d"; _first=0; else printf ', %s' "$_d"; fi
  done <<< "$DESTS"
  printf '\n'
fi

# Per-machine configuration, parsed BEFORE the dry-run exit so --dry-run shows the
# warning too (header documents the env vars / config files).
#   MIGRATION_REPOS / ~/.claude-migration-repos        git repos to record
#   MIGRATION_EXTRA_FILES / ~/.claude-migration-extra-files   extra files to capture
REPOS=()
if [ -n "${MIGRATION_REPOS:-}" ]; then
  IFS=: read -ra REPOS <<< "$MIGRATION_REPOS"
elif [ -f "$SRC/.claude-migration-repos" ]; then
  while IFS= read -r r; do case "$r" in ''|'#'*) continue ;; esac; REPOS+=("$r"); done \
    < "$SRC/.claude-migration-repos"
fi
[ "${#REPOS[@]}" -eq 0 ] && warn "no repos configured (MIGRATION_REPOS / ~/.claude-migration-repos) — recording none"
EXTRA_FILES=()
if [ -n "${MIGRATION_EXTRA_FILES:-}" ]; then
  IFS=: read -ra EXTRA_FILES <<< "$MIGRATION_EXTRA_FILES"
elif [ -f "$SRC/.claude-migration-extra-files" ]; then
  while IFS= read -r r; do case "$r" in ''|'#'*) continue ;; esac; EXTRA_FILES+=("$r"); done \
    < "$SRC/.claude-migration-extra-files"
fi

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
# (Guarded like copy_rel: a fresh machine without .claude must not crash here.)
if [ -e "$SRC/.claude" ]; then
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
else
  warn "skip (missing): .claude"
fi
# NOTE: symlinks inside .claude (e.g. skills linked into a workspace dir) are
# preserved AS symlinks by rsync -a; restore.sh rewrites the ones pointing into
# the source home to the new $HOME (source home is recorded in meta.env).

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
# Extra per-machine files, parsed up top (MIGRATION_EXTRA_FILES / the config file).
for f in ${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}; do copy_rel "$f"; done

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
# Repos were configured up top (MIGRATION_REPOS / ~/.claude-migration-repos).
: > "$STAGE/repos.tsv"   # path<TAB>url<TAB>branch<TAB>sha
# bash-3.2 + set -u: an empty REPOS array must not crash here (the ${var+...} guard
# keeps the expansion empty instead of raising "unbound variable").
for rel in ${REPOS[@]+"${REPOS[@]}"}; do
  d="$SRC/$rel"
  [ -d "$d/.git" ] || { warn "not a git repo, skipping repo-mode: $rel"; continue; }
  url="$(git -C "$d" remote get-url origin 2>/dev/null || echo '')"
  sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '')"
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"
  printf '%s\t%s\t%s\t%s\n' "$rel" "$url" "$branch" "$sha" >> "$STAGE/repos.tsv"
  # overlay = modified + untracked, gitignore-respected (excludes .venv etc.)
  safe="$(echo "$rel" | tr '/' '__')"
  ( cd "$d"
    git -c core.quotepath=false ls-files -z -m -o --exclude-standard \
      | tr '\0' '\n' \
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
ROOTDIR="$(cd "$(dirname "$0")" && pwd)"
printf 'SOURCE_USER=%s\nSOURCE_HOME=%s\nTOOL_VERSION=%s\n' \
  "$(id -un)" "$SRC" "$(tr -d '[:space:]' < "$ROOTDIR/VERSION" 2>/dev/null || echo dev)" \
  > "$STAGE/meta.env"
cat > "$STAGE/MANIFEST.md" <<'MD'
# Claude Code migration archive

Generated by backup.sh. Restore with `restore.sh` on the new Mac. The source
user/home are in `meta.env`; restore.sh rewrites absolute-path symlinks that
point into the source home to the new $HOME. Contains local-only STATE; public
payloads are reinstalled.

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
- Git repos (clone + checkout recorded SHA + overlay): the paths in `repos.tsv`
  (configured per machine via MIGRATION_REPOS / ~/.claude-migration-repos).
- Virtualenvs (uv sync) and node_modules (npm install) for the recorded repos.
- pipx tools (from pipx-list.txt).

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

# Copy the finished archive to every additional chosen destination, size-verified.
# A failed convenience copy warns and never fails the backup — the primary exists.
# Single-destination runs (piped/scripted/positional-arg) skip all of this and the
# DONE line stays byte-identical to the pre-menu shape.
_DEST_SUFFIX=""
while IFS= read -r _d; do
  [ -z "$_d" ] && continue
  if [ "$_d" != "$OUT" ]; then
    _target="$_d/$(basename "$ARCHIVE")"
    # The default destination may not exist yet when it is a SECONDARY (the primary
    # is created by the main flow) — the user picked it, so create it. mkdir is INSIDE
    # the guarded if: under set -euo pipefail a bare failing mkdir would abort the whole
    # script; here an uncreatable target simply lands in the warn branch.
    if { [ -d "$_d" ] || mkdir -p -- "$_d" 2>/dev/null; } \
       && cp -p -- "$ARCHIVE" "$_target" 2>/dev/null \
       && [ "$(stat -f %z "$ARCHIVE" 2>/dev/null)" = "$(stat -f %z "$_target" 2>/dev/null)" ]; then
      log "copied → $_target"
    else
      warn "could not copy to $_d (skipped) — the primary archive is intact"
    fi
  fi
done <<< "$DESTS"
if [ "$(printf '%s\n' "$DESTS" | grep -c .)" -gt 1 ]; then
  _DEST_SUFFIX=" — destinations: "
  _first=1
  while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    if [ "$_first" -eq 1 ]; then _DEST_SUFFIX="$_DEST_SUFFIX$_d (primary)"; _first=0; else _DEST_SUFFIX="$_DEST_SUFFIX, $_d"; fi
  done <<< "$DESTS"
fi
rm -rf "$STAGE"

SIZE="$(du -sh "$ARCHIVE" | cut -f1)"
echo
log "DONE. Archive: $ARCHIVE  ($SIZE)${_DEST_SUFFIX}"
warn "This archive contains SECRETS. Move it to the new Mac over AirDrop/USB, not cloud."
echo "Next: copy restore.sh + this archive to the new Mac, then run:"
echo "    bash restore.sh \"$ARCHIVE\""
