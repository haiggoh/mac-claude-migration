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
#   Unset MIGRATION_REPOS = repos are DISCOVERED automatically (0.2.0): $HOME is
#   scanned (pruned), found repos merge into ~/.claude-migration-repos (prefixes:
#   bare = record, ! = exclude, + = copy whole, ? = undecided), and anything mcm
#   cannot decide alone is asked once and remembered (--reset-choices or the
#   startup menu undo that).
#   The source user/home are recorded in meta.env so restore.sh
#   can rewrite absolute-path symlinks on a machine with a different username.
#
# Usage: bash backup.sh            # interactive on a terminal: destination menu — a
#                                  # local pick builds the archive there (kept); a cloud-only
#                                  # pick builds once in a temp dir, copies sha256-verified to
#                                  # each cloud dir, temp auto-removed after the first verified
#                                  # copy; piped/scripted: writes into ~/claude-migration
#        bash backup.sh /some/dir  # writes into /some/dir (menu stays shut)
#        bash backup.sh --list-destinations
#                                  # print candidate destinations (path<TAB>label), exit
#
# Rebuildable build output is never archived (0.3.1): node_modules, .venv, venv,
# __pycache__, any directory holding a CACHEDIR.TAG, and cargo target/ dirs
# (recognised by .rustc_info.json or a <profile>/.fingerprint). On a terminal run
# ~/.claude/backups is offered with its size: include it (Enter) or leave it out.
#
# Progress (0.3.1): when stderr is a terminal, long steps show a live status line
# on stderr: spinner + elapsed time always, plus a bar and percentage for packing
# (files) and cloud copies (bytes). Piped/scripted runs stay plain.
#   MCM_PROGRESS=1  force the status line on (e.g. through a pipe); 0 = force off;
#                   any other value exits 2.
#
set -euo pipefail

# --- argument parsing MUST come before any work -------------------------------
# A user probing an unfamiliar script with --help expects to be told something,
# not to trigger a backup that writes a tarball full of secrets.
usage() {
  # print the whole header comment block, whatever its length (a fixed range once hid
  # every line added past it — measured on rtc-ship 0.6.11)
  awk 'NR==1 {next} !/^#/ {exit} {line=$0; sub(/^# ?/, "", line); if (line == "" && !started) next; started=1; print line}' "$0"
  printf 'Options:\n  -h, --help   show this help and exit\n  --dry-run    print what would be captured, then exit without writing\n  --list-destinations\n               print candidate destinations (path<TAB>label, default first) and exit\n  --reset-choices\n               forget remembered repo choices (repo mode + list answers) and ask\n               again on this run; needs a terminal\n'
}
DRY_RUN=0
LIST_DESTS=0
RESET_CHOICES=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --dry-run) DRY_RUN=1; shift;;
    --list-destinations) LIST_DESTS=1; shift;;
    --reset-choices) RESET_CHOICES=1; shift;;
    -*) printf '%s: unknown option: %s\n' "${0##*/}" "$1" >&2
        # shellcheck disable=SC2016  # the backticks are literal text in the hint, not a substitution
        printf 'Try `%s --help`.\n' "${0##*/}" >&2; exit 2;;
    *) ARGS+=("$1"); shift;;
  esac
done
if [ "${#ARGS[@]}" -gt 1 ]; then
  printf '%s: expected at most one output directory, got %d\n' "${0##*/}" "${#ARGS[@]}" >&2
  exit 2
fi
set -- "${ARGS[@]+"${ARGS[@]}"}"
# An explicit override that is set but invalid fails loudly, before any work.
case "${MCM_PROGRESS:-}" in
  "") _PROGRESS=0; if [ -t 2 ]; then _PROGRESS=1; fi ;;
  1)  _PROGRESS=1 ;;
  0)  _PROGRESS=0 ;;
  *)  printf '%s: MCM_PROGRESS must be 0 or 1 (got: %s)\n' "${0##*/}" "$MCM_PROGRESS" >&2; exit 2 ;;
esac

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
# scripted, hook and explicit-arg runs take exactly the old path. The archive is
# BUILT in the primary (first picked) destination; the rest get copies.
# Grammar: Enter/d = default; "1 3" or "1,3" = several (first = primary); a = all
# detected CLOUD directories (entries 2..n — the local default is entry 1 and is not
# cloud; with no cloud dirs detected 'a' collapses to the default); c = custom
# directory (a missing one needs a [y/N] confirm; --dry-run only announces it);
# q or EOF = abort, exit 1 (this menu is the pre-commitment screen — q stays HERE only).
# 0.3.0 cloud semantics: when the pick contains a cloud dir but NO local dir, the
# archive is built ONCE in a temp dir, copied sequentially + sha256-verified to each
# chosen cloud dir, and the temp dir is auto-removed after the first verified copy.
_is_cloud_dest() {  # rc 0 when <path> is a detected cloud-sync directory
  case "$1" in
    "$HOME/Library/CloudStorage/"*|"$HOME/Library/Mobile Documents/"*|"$HOME/Dropbox"|"$HOME/Dropbox/"*|"$HOME/OneDrive"|"$HOME/OneDrive/"*)
      return 0 ;;
  esac
  return 1
}
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
    printf '  Enter = default only    numbers = pick several (e.g. 1 3 or 1,3)    a = all detected cloud directories\n' >&2
    printf '  c = custom directory    q = abort the backup\n\n' >&2
    read -r ans || ans="q"          # EOF at the prompt aborts like q — never spin on a closed pipe
    ans="${ans//[,,]/ }"            # comma form of the number grammar
    case "$ans" in
      ""|d|D) picked="1"; break ;;
      q|Q) warn "backup aborted — nothing was written" >&2; exit 1 ;;
      a|A)
        if [ "$n" -gt 1 ]; then
          i=2; picked=""   # entries 2..n are the detected CLOUD dirs; entry 1 (local default) is not
          while [ "$i" -le "$n" ]; do picked="$picked${picked:+$'\n'}$i"; i=$((i + 1)); done
        else
          picked="1"       # no cloud dirs detected: 'a' collapses to the default
        fi
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

# --- repo discovery (0.2.0) ------------------------------------------------------
# Top-level dirs the archive captures WHOLESALE. This list is the single source
# for two behaviours: the copy steps below iterate it (so a dir added here gets
# copied), and discovery prunes it (so a repo inside one is never discovered —
# it is either already in the archive or machine-local tool state). One list,
# two consumers, no drift.
CAPTURED_WHOLESALE=".claude .claude-flow .joyia .ssh"

# Repo roots at depth <= 4 are found (their .git entry sits at <= 5). The
# binding floor is a per-branch worktree pool nested two dirs deep (.git FILE
# at depth 4); 5 keeps the real-home walk far under the ~10 s budget (measured
# — see the handoff progress log). The limit lives INSIDE _discover_repos as a
# local so the function is self-contained (tests extract it by range).

_discover_repos() {  # print $HOME-relative repo roots, one per line
  local hits hit root rel acc nested maxdepth=5
  local -a prune=() accepted=() result=()
  prune=( -path "$HOME/Library"          # covers CloudStorage, Mobile Documents, caches
          -o -path "$HOME/Dropbox"
          -o -path "$HOME/OneDrive"
          -o -path "$HOME/.Trash"
          -o -path "$HOME/.cache"
          -o -path "$HOME/.npm"
          -o -path "$HOME/.cargo"
          -o -path "$HOME/.rustup"
          -o -path "$HOME/go/pkg"
          -o -path "$HOME/claude-migration"
          -o -name node_modules          # name prunes apply at ANY depth
          -o -name .venv
          -o -name venv
          -o -name __pycache__ )
  for root in $CAPTURED_WHOLESALE; do prune+=(-o -path "$HOME/$root"); done
  # A non-zero find (permission-denied subtrees are ordinary on a real home)
  # must NOT discard the partial results: capture what was found, swallow rc.
  hits="$(find "$HOME" -maxdepth "$maxdepth" \
            \( "${prune[@]}" \) -prune -o -name .git -print 2>/dev/null)" || true
  # A root is any dir holding .git — a DIRECTORY (normal repo) or a FILE
  # (linked worktree). find's output is converted to $HOME-relative roots.
  # $HOME itself is never a recorded root (recording it would overlay the
  # whole home); anything not under $HOME is ignored as a guard.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    root="${hit%/.git}"
    [ "$root" = "$HOME" ] && continue
    rel="${root#"$HOME"/}"
    [ "$rel" = "$root" ] && continue
    accepted+=("$rel")
  done <<< "$hits"
  # Nested suppression, order-independent: a root with an accepted ANCESTOR is
  # a repo inside a repo (or a submodule) and is not listed separately. An
  # order-dependent first-accept filter would leak when a descendant sorts
  # before its ancestor (e.g. a repo dir named "*x" under C collation).
  for rel in ${accepted[@]+"${accepted[@]}"}; do
    nested=0
    for acc in ${accepted[@]+"${accepted[@]}"}; do
      [ "$acc" = "$rel" ] && continue
      case "$rel" in "$acc"/*) nested=1; break ;; esac
    done
    [ "$nested" -eq 0 ] && result+=("$rel")
  done
  for rel in ${result[@]+"${result[@]}"}; do printf '%s\n' "$rel"; done
  return 0
}

_repo_remote() {  # <abs-dir> — origin URL, else first remote URL, else empty
  local url first
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then printf '%s\n' "$url"; return 0; fi
  first="$(git -C "$1" remote 2>/dev/null | head -n 1)"
  if [ -n "$first" ]; then
    url="$(git -C "$1" remote get-url "$first" 2>/dev/null || true)"
  fi
  if [ -n "$url" ]; then printf '%s\n' "$url"; fi
  return 0
}

# --- repo list file (0.2.0) ------------------------------------------------------
# ~/.claude-migration-repos stays hand-editable; the canonical line grammar:
#   path     record — remote URL + exact commit + uncommitted overlay on restore
#   !path    exclude — never offered again
#   +path    copy — whole tree incl. .git into repo-copies/ in the archive
#   ?path    undecided — found without a remote on a non-terminal run
#   # ...    comment — preserved verbatim on rewrite (blank lines too)
# Read is liberal (design builder call 4): surrounding whitespace, a leading
# `~/`, trailing `/` and a trailing CR are stripped; only `!`/`+`/`?` are
# prefixes, any other line is a bare record. Read emits one `state<TAB>payload`
# line per input line — state record|exclude|copy|undecided|comment; a comment
# payload is the verbatim line so the flow rebuilds the file losslessly (ledger
# ruling: user comments survive rewrites). Write converts merged state lines
# back to canonical file lines, prepends the generated header only when the
# file is created, and writes atomically (mktemp in the same dir + mv).

_read_repo_list() {  # _read_repo_list <file> — print state<TAB>payload, one per line
  local file="$1" line trimmed state path
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                                # CRLF files read clean
    trimmed="$line"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"    # strip surrounding whitespace
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$trimmed" in
      ''|'#'*) printf 'comment\t%s\n' "$line"; continue ;;   # verbatim, blank lines included
    esac
    case "$trimmed" in
      '!'*) state=exclude;   path="${trimmed:1}" ;;
      '+'*) state=copy;      path="${trimmed:1}" ;;
      '?'*) state=undecided; path="${trimmed:1}" ;;
      *)   state=record;    path="$trimmed" ;;
    esac
    path="${path#"${path%%[![:space:]]*}"}"              # whitespace after the prefix
    path="${path%"${path##*[![:space:]]}"}"
    while [ "$path" != "${path%/}" ] && [ "$path" != "/" ]; do path="${path%/}"; done
    # shellcheck disable=SC2088  # '~/' must match a LITERAL tilde — $HOME would never match it
    case "$path" in
      '~/'*) path="${path:2}" ;;
      '~')   path="" ;;
    esac
    if [ -z "$path" ]; then printf 'comment\t%s\n' "$line"; continue; fi
    printf '%s\t%s\n' "$state" "$path"
  done < "$file"
  return 0
}

_write_repo_list() {  # _write_repo_list <file> <merged-content> — atomic write, header on create
  local file="$1" content="$2" tmp line state payload
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  {
    if [ ! -e "$file" ]; then
      # shellcheck disable=SC2016  # $HOME and the backticks are literal text in the generated header
      printf '%s\n' \
        '# Repo list for backup.sh — one path per line, relative to $HOME.' \
        '#   path    record: remote URL + exact commit + uncommitted overlay on restore' \
        '#   !path   excluded: never offered again' \
        '#   +path   copy the whole tree (incl. .git) into the archive (repo-copies/)' \
        '#   ?path   undecided: found without a remote on a non-terminal run' \
        '# Forget remembered answers and ask again: `backup.sh --reset-choices`,' \
        '# or the startup menu on a terminal run.'
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      state="${line%%$'\t'*}"
      payload="${line#*$'\t'}"
      case "$state" in
        exclude)   printf '!%s\n' "$payload" ;;
        copy)      printf '+%s\n' "$payload" ;;
        undecided) printf '?%s\n' "$payload" ;;
        comment)   printf '%s\n' "$payload" ;;    # verbatim line
        *)         printf '%s\n' "$payload" ;;    # record: bare canonical path
      esac
    done <<< "$content"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  return 0
}

_merge_decided() {  # _merge_decided <path> — rc 0 when the path is already decided
  local p="$1" x
  for x in ${DECIDED_RECORD[@]+"${DECIDED_RECORD[@]}"} \
           ${DECIDED_EXCLUDE[@]+"${DECIDED_EXCLUDE[@]}"} \
           ${DECIDED_COPY[@]+"${DECIDED_COPY[@]}"} \
           ${DECIDED_UNDECIDED[@]+"${DECIDED_UNDECIDED[@]}"}; do
    [ "$x" = "$p" ] && return 0
  done
  return 1
}

_merge_in_missing() {  # _merge_in_missing <path> — rc 0 when listed but not on disk
  local p="$1" x
  for x in ${MISSING[@]+"${MISSING[@]}"}; do
    [ "$x" = "$p" ] && return 0
  done
  return 1
}

_merge_repos() {  # stdin: state<TAB>payload lines (from _read_repo_list); args: discovered rel paths
  # Sets DECIDED_RECORD/EXCLUDE/COPY/UNDECIDED, NEW_REMOTE, NEW_NOREMOTE, MISSING,
  # MERGE_LINES (the read lines in order, for a lossless rewrite).
  local state payload path d url
  DECIDED_RECORD=(); DECIDED_EXCLUDE=(); DECIDED_COPY=(); DECIDED_UNDECIDED=()
  NEW_REMOTE=(); NEW_NOREMOTE=(); MISSING=(); MERGE_LINES=()
  while IFS=$'\t' read -r state payload; do
    [ -n "$state" ] || continue
    MERGE_LINES+=("$state"$'\t'"$payload")
    case "$state" in
      record|exclude|copy|undecided)
        path="$payload"
        while [ "$path" != "${path%/}" ] && [ "$path" != "/" ]; do path="${path%/}"; done
        [ -n "$path" ] || continue
        case "$state" in
          record)    DECIDED_RECORD+=("$path") ;;
          exclude)   DECIDED_EXCLUDE+=("$path") ;;
          copy)      DECIDED_COPY+=("$path") ;;
          undecided) DECIDED_UNDECIDED+=("$path") ;;
        esac
        if [ ! -d "$HOME/$path" ]; then
          MISSING+=("$path")
          warn "listed repo missing: $path"    # the line is kept; the decision stands
        fi
        ;;
    esac
  done
  for d in "$@"; do
    while [ "$d" != "${d%/}" ] && [ "$d" != "/" ]; do d="${d%/}"; done
    [ -n "$d" ] || continue
    _merge_decided "$d" && continue
    url=""
    # .git as FILE = linked worktree — still a repo root with the shared remotes
    if [ -e "$HOME/$d/.git" ]; then url="$(_repo_remote "$HOME/$d")"; fi
    if [ -n "$url" ]; then NEW_REMOTE+=("$d"); else NEW_NOREMOTE+=("$d"); fi
  done
  return 0
}

# --- prompts, menus, prefs (0.2.0) ----------------------------------------------
# Remembered settings live in ~/.claude-migration-prefs as key=value lines
# (starting with repo_mode=review|auto). All menu chrome goes to STDERR; only
# results travel on stdout (the _choose_destinations convention). Post-destination
# prompts (0.3.0) offer NO abort: EOF/Enter takes the default answer — never spin
# on a closed pipe. Only the destination menu itself (and the front door) abort on q/EOF.
_read_ans() {  # _read_ans <var> — read one line into <var>. On EOF set <var>="" AND
               # point stdin at /dev/null for the REST of this shell: a pty delivers
               # EOF only once, so without this the NEXT read blocks forever on a
               # closed pipe (measured 2026-11-24: hung at the second prompt).
  local _v="$1"
  # shellcheck disable=SC2229  # intentional: read into the variable NAMED by $_v
  if read -r "$_v"; then return 0; fi
  exec 0</dev/null
  printf -v "$_v" '%s' ''
  return 0   # EOF-is-default is not an error; rc 1 here would kill the script under set -e
}

_read_pref() {  # _read_pref <key> — print the value of the last key= line; rc 1 when absent
  local key="$1" line k v f
  f="${PREFSFILE:-$HOME/.claude-migration-prefs}"
  [ -f "$f" ] || return 1
  v=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '#'*|"") continue ;;
    esac
    k="${line%%=*}"
    if [ "$k" = "$key" ]; then v="${line#*=}"; fi
  done < "$f"
  if [ -z "$v" ]; then return 1; fi
  printf '%s\n' "$v"
  return 0
}

_write_pref() {  # _write_pref <key> <value> — atomic; empty value deletes the key; other lines kept
  local key="$1" val="$2" f tmp line k wroteline=0
  f="${PREFSFILE:-$HOME/.claude-migration-prefs}"
  tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 1
  {
    if [ -f "$f" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
          '#'*|"") printf '%s\n' "$line"; continue ;;
        esac
        k="${line%%=*}"
        if [ "$k" = "$key" ]; then
          if [ -n "$val" ]; then printf '%s=%s\n' "$key" "$val"; wroteline=1; fi
        else
          printf '%s\n' "$line"
        fi
      done < "$f"
    fi
    if [ "$wroteline" -eq 0 ] && [ -n "$val" ]; then
      printf '%s=%s\n' "$key" "$val"
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
  return 0
}

_repo_size() {  # _repo_size <abs-dir> — human size of tracked+untracked files (gitignore-respected).
                 # Paths are made absolute so stat works from any cwd (a bare relative
                 # path made the pipeline rc 1 under pipefail — invisible while this ran
                 # inside a $() where set -e is suppressed, fatal in the main shell).
                 # Always rc 0: callers assign the result under set -e.
  local _s=""
  _s="$(git -C "$1" ls-files -z -c -o --exclude-standard 2>/dev/null \
        | xargs -0 -I{} stat -f %z "$1/{}" 2>/dev/null \
        | awk '{s+=$1} END {printf "%.1f MB", s / 1048576}')" || true
  printf '%s\n' "$_s"
  return 0
}

_ask_repo_mode() {  # sets _MODE_ANS=review|auto. Post-destination prompt (0.3.0):
                    # NO abort offered; EOF/Enter = default (review). Runs in the MAIN
                    # shell (not $()) so its EOF redirect covers every later prompt.
  local ans ans2
  while true; do
    printf '\n📦 How should I record the repos I found?\n' >&2
    printf '   1) review — show the new repos first (Enter)\n' >&2
    printf '   2) automatic — record repos with a remote without asking\n' >&2
    _read_ans ans
    case "$ans" in
      ""|1) ans="review" ;;
      2) ans="auto" ;;
      *) printf '  Unrecognized: %s\n' "$ans" >&2; continue ;;
    esac
    printf 'Remember this choice for future runs? [y/N] ' >&2
    _read_ans ans2
    case "$ans2" in
      y|Y|yes|YES) _write_pref repo_mode "$ans" ;;
      *) : ;;
    esac
    _MODE_ANS="$ans"
    return 0
  done
}

_startup_menu() {  # sets _MENU_ANS: ""=carry on | change | rescan.
                    # Post-destination prompt (0.3.0): NO abort offered; EOF/Enter = carry on.
  local ans
  while true; do
    printf '\n📦 Remembered choices found (repo mode / list answers)\n' >&2
    printf '   1) carry on with them (Enter)\n' >&2
    printf '   2) change them (re-ask the mode; re-decide excluded and copied repos)\n' >&2
    printf '   3) re-scan from scratch (ignore the list file this run, then rewrite it)\n\n' >&2
    _read_ans ans
    case "$ans" in
      ""|1) _MENU_ANS=""; return 0 ;;
      2|c)  _MENU_ANS="change"; return 0 ;;
      3|r)  _MENU_ANS="rescan"; return 0 ;;
      *)    printf '  Unrecognized: %s\n' "$ans" >&2 ;;
    esac
  done
}

_ask_no_remote() {  # _ask_no_remote <rel> — sets _NR_ANS=copy|skip. Post-destination
                     # prompt (0.3.0): NO abort offered; EOF/Enter = default (copy).
  local rel="$1" ans sz
  sz="$(_repo_size "$SRC/$rel")"
  while true; do
    printf "\n📦 Repo '%s' has no remote (size without gitignored files: %s)\n" "$rel" "$sz" >&2
    printf '   1) copy the whole tree into the archive (incl. .git history)\n' >&2
    printf '   2) leave it out\n\n' >&2
    _read_ans ans
    case "$ans" in
      ""|1) _NR_ANS="copy"; return 0 ;;
      2)    _NR_ANS="skip"; return 0 ;;
      *)    printf '  Unrecognized: %s\n' "$ans" >&2 ;;
    esac
  done
}

_ask_no_remote_batch() {  # _ask_no_remote_batch <rel>... — sets _NRB_ANS=all|none|each|pick
                           # (pick: _NRB_PICK[] = the chosen rel paths). One batch menu for ALL
                           # no-remote repos (new + parked `?`). 0.3.1: the actions are LETTERS so
                           # numbers always mean repos ("2,7" = copy just those, leave the rest out —
                           # the 0.3.0 menu read a repo number as an action). NO abort offered;
                           # EOF/Enter = default (all).
  local -a paths=() pick=()
  local i ans sz tok okp
  for i in "$@"; do paths+=("$i"); done
  while true; do
    printf '\n📦 %d repo(s) have no remote (not re-clonable from anywhere):\n' "${#paths[@]}" >&2
    i=0
    while [ "$i" -lt "${#paths[@]}" ]; do
      sz="$(_repo_size "$SRC/${paths[$i]}")"
      printf '   %d) %s  (%s without gitignored files)\n' "$((i + 1))" "${paths[$i]}" "$sz" >&2
      i=$((i + 1))
    done
    printf '\n   a) copy ALL of them into the archive (incl. .git history)  (Enter)\n' >&2
    printf '   n) leave ALL of them out\n' >&2
    printf '   o) decide one by one\n' >&2
    printf '   numbers = copy just those, leave the rest out (e.g. 2,7 or 2 7)\n\n' >&2
    _read_ans ans
    case "$ans" in
      ""|a|A) _NRB_ANS="all"; return 0 ;;
      n|N)    _NRB_ANS="none"; return 0 ;;
      o|O)    _NRB_ANS="each"; return 0 ;;
    esac
    okp=1; pick=()
    set -f                                  # tokenizing is the point; "*" must not glob
    for tok in ${ans//,/ }; do
      case "$tok" in
        ''|*[!0-9]*|??????*) okp=0; break ;;   # >=6 digits: no list is that long, and `[` would error
      esac
      if [ "$tok" -lt 1 ] || [ "$tok" -gt "${#paths[@]}" ]; then okp=0; break; fi
      pick+=("${paths[tok - 1]}")
    done
    set +f
    if [ "$okp" -eq 1 ] && [ "${#pick[@]}" -gt 0 ]; then
      _NRB_ANS="pick"; _NRB_PICK=("${pick[@]}"); return 0
    fi
    printf '  Unrecognized: %s\n' "$ans" >&2
  done
}

_review_new_repos() {  # _review_new_repos <rel>... — sets ACCEPTED[] (pre-ticked; toggle by number; a/n/Enter).
                         # Post-destination prompt (0.3.0): NO abort offered; EOF/Enter = accept.
  local -a paths=() ticked=()
  local i ans tok okn
  for i in "$@"; do paths+=("$i"); ticked+=("1"); done
  while true; do
    printf '\n📦 New repos with a remote (ticked = will be recorded)\n' >&2
    i=0
    while [ "$i" -lt "${#paths[@]}" ]; do
      if [ "${ticked[$i]}" -eq 1 ]; then
        printf '   [x] %d) %s\n' "$((i + 1))" "${paths[$i]}" >&2
      else
        printf '   [ ] %d) %s\n' "$((i + 1))" "${paths[$i]}" >&2
      fi
      i=$((i + 1))
    done
    printf '   a = tick all   n = tick none   Enter = accept\n\n' >&2
    _read_ans ans
    case "$ans" in
      "") break ;;
      a|A) i=0; while [ "$i" -lt "${#ticked[@]}" ]; do ticked[i]=1; i=$((i + 1)); done ;;
      n|N) i=0; while [ "$i" -lt "${#ticked[@]}" ]; do ticked[i]=0; i=$((i + 1)); done ;;
      *)
        okn=1
        set -f
        for tok in $ans; do
          case "$tok" in
            ''|*[!0-9]*) okn=0; break ;;
          esac
          if [ "$tok" -lt 1 ] || [ "$tok" -gt "${#paths[@]}" ]; then okn=0; break; fi
          if [ "${ticked[tok - 1]}" -eq 1 ]; then ticked[tok - 1]=0; else ticked[tok - 1]=1; fi
        done
        set +f
        if [ "$okn" -eq 0 ]; then printf '  Unrecognized: %s\n' "$ans" >&2; fi
        ;;
    esac
  done
  ACCEPTED=()
  i=0
  while [ "$i" -lt "${#paths[@]}" ]; do
    if [ "${ticked[$i]}" -eq 1 ]; then ACCEPTED+=("${paths[$i]}"); fi
    i=$((i + 1))
  done
  return 0
}

_merge_drop_line() {  # _merge_drop_line <state> <path> — remove that line from MERGE_LINES in place
  local st="$1" p="$2" _l
  local -a keep=()
  for _l in ${MERGE_LINES[@]+"${MERGE_LINES[@]}"}; do
    if [ "$_l" = "$st"$'\t'"$p" ]; then continue; fi
    keep+=("$_l")
  done
  MERGE_LINES=()
  for _l in ${keep[@]+"${keep[@]}"}; do MERGE_LINES+=("$_l"); done
  return 0
}

# --list-destinations is a probe, like --dry-run: print the candidates and exit
# BEFORE any work — no config parsing, no staging, nothing written.
if [ "$LIST_DESTS" = 1 ]; then
  _candidate_destinations "${1:-$HOME/claude-migration}"
  exit 0
fi

# --- --reset-choices gate (0.2.0): before any work -----------------------------
# Needs a terminal: in a non-terminal run it exits 2 saying so rather than
# silently doing nothing (it would otherwise un-exclude repos with nobody there
# to answer). MIGRATION_REPOS overrides everything (no discovery, no prompts,
# no file writes), so the reset cannot act under it. --dry-run only announces.
if [ "$RESET_CHOICES" -eq 1 ]; then
  if [ -n "${MIGRATION_REPOS:-}" ]; then
    printf '%s: --reset-choices cannot run with MIGRATION_REPOS set — the env var overrides everything\n' "${0##*/}" >&2
    exit 2
  fi
  if ! { [ -t 0 ] && [ -t 1 ]; }; then
    printf '%s: --reset-choices needs a terminal (it re-asks remembered answers interactively)\n' "${0##*/}" >&2
    exit 2
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: --reset-choices would delete repo_mode from %s and re-ask every !, + and ? entry in %s. Nothing changed.\n' \
      "$HOME/.claude-migration-prefs" "$HOME/.claude-migration-repos"
  fi
fi

SRC="$HOME"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$HOME/claude-migration}"
STAGE="$OUT/stage-$STAMP"
HOMEDIR="$STAGE/home"          # mirrors a subset of $HOME
ARCHIVE="$OUT/claude-migration-$STAMP.tar.gz"

_TICK_PID=""
_tick_clear() { if [ -n "$_TICK_PID" ]; then printf '\r\033[K' >&2; fi; return 0; }   # keep log lines off the status line
log() { _tick_clear; printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
warn(){ _tick_clear; printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
note(){ _tick_clear; printf '%s\n' "$*"; }

# --- progress / aliveness (0.3.1) ---------------------------------------------------
# A 65 GB pack ran 27+ min with NO output and read as wedged (2026-11-24). Long steps
# now draw ONE status line on stderr — spinner + elapsed always, a bar + percentage
# when the total is known — but only when _PROGRESS=1 (stderr is a terminal, or
# MCM_PROGRESS=1). The ticker is a background loop the main shell starts and stops;
# it also exits on its own when the main shell is gone (kill -0 on the parent).
_progress_bar() {  # _progress_bar <cur> <total> <width> — "[####------]  40%"; total<=0 -> 0%, clamped at 100%
  local cur="$1" total="$2" width="$3" pct fill bar="" i=0
  if [ "$total" -le 0 ]; then pct=0; else pct=$(( cur * 100 / total )); fi
  if [ "$pct" -gt 100 ]; then pct=100; fi
  fill=$(( pct * width / 100 ))
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$fill" ]; then bar="$bar#"; else bar="$bar-"; fi
    i=$((i + 1))
  done
  printf '[%s] %3d%%\n' "$bar" "$pct"
}
_human_bytes() {  # _human_bytes <bytes> — "512 B" / "1.5 KB" / "5.0 MB" / "15.0 GB" (C locale: always a dot)
  LC_ALL=C awk -v b="$1" 'BEGIN {
    if (b < 1024) printf "%d B\n", b
    else if (b < 1048576) printf "%.1f KB\n", b / 1024
    else if (b < 1073741824) printf "%.1f MB\n", b / 1048576
    else printf "%.1f GB\n", b / 1073741824 }'
}
_fmt_elapsed() {  # _fmt_elapsed <seconds> — "0m07s" / "12m03s"
  printf '%dm%02ds\n' "$(( $1 / 60 ))" "$(( $1 % 60 ))"
}
_tick_frame() {  # _tick_frame <spin> <label> <mode> <arg> <total> <elapsed-s> — one status line, no newline.
                 # Must NEVER fail the run: its input file may not exist yet (the first frame is
                 # drawn before tar creates its log — under set -e + pipefail a bare `< missing`
                 # redirect killed the whole backup, measured 2026-11-24).
  local cur=0 tot rest detail=""
  case "$3" in
    count) if [ -f "$4" ]; then cur="$(wc -l < "$4" | tr -d ' ')" || cur=0; fi
           cur="${cur:-0}"
           detail="$(_progress_bar "$cur" "$5" 24)  $cur/$5 files" ;;
    size)  cur="$(stat -f %z "$4" 2>/dev/null || echo 0)"
           detail="$(_progress_bar "$cur" "$5" 24)  $(_human_bytes "$cur") / $(_human_bytes "$5")" ;;
    state) cur=0; tot=0; rest=""
           if [ -s "$4" ]; then read -r cur tot rest < "$4" || true; fi
           detail="$(_progress_bar "$cur" "$tot" 24)  $cur/$tot  $rest" ;;
  esac
  printf '\r\033[K%s %s  %s  %s' "$1" "$2" "$detail" "$(_fmt_elapsed "$6")" >&2
}
_ticker_start() {  # _ticker_start <label> <none|count|size|state> [arg] [total] — no-op unless _PROGRESS=1
                   # count: arg = a log gaining one line per item; size: arg = a growing file;
                   # state: arg = a file holding "<cur> <total> <text>" the caller rewrites
  [ "$_PROGRESS" -eq 1 ] || return 0
  _ticker_stop
  local label="$1" mode="$2" arg="${3:-}" total="${4:-0}" parent=$$ start
  start="$(date +%s)"
  _tick_frame '⠋' "$label" "$mode" "$arg" "$total" 0 || true   # first frame NOW: a short step still shows
  (
    trap - INT TERM HUP EXIT
    spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); i=1
    while kill -0 "$parent" 2>/dev/null; do
      sleep 0.2
      _tick_frame "${spin[$((i % 10))]}" "$label" "$mode" "$arg" "$total" "$(( $(date +%s) - start ))" || true
      i=$((i + 1))
    done
  ) &
  _TICK_PID=$!
  return 0
}
_ticker_stop() {  # stop the status line (if any) and clear it
  if [ -z "$_TICK_PID" ]; then return 0; fi
  kill "$_TICK_PID" 2>/dev/null || true
  wait "$_TICK_PID" 2>/dev/null || true
  printf '\r\033[K' >&2
  _TICK_PID=""
  return 0
}

# --- build output (0.3.1) -------------------------------------------------------------
# 62 GB of the 65 GB stage on 2026-11-24 was cargo target/ dirs inside
# ~/.claude/backups/worktrees/* — copied WITHOUT their CACHEDIR.TAG, so the tag
# alone recognises none of them (measured). A target/ dir counts as cargo output
# when it holds .rustc_info.json, CACHEDIR.TAG, or a <profile>/.fingerprint; any
# other dir counts when it holds CACHEDIR.TAG (the cache-directory standard: "do
# not back me up"). A plain dir that merely is NAMED target is kept.
_build_output_dirs() {  # _build_output_dirs <rel> — run from $SRC; print rebuildable build-output dirs under <rel>
  local p f is
  [ -d "$1" ] || return 0
  { find "$1" \( -name node_modules -o -name .venv -o -name venv -o -name __pycache__ -o -name .git \) -prune \
        -o -type d -name target -print -prune \
        -o -type f -name CACHEDIR.TAG -print 2>/dev/null || true; } \
  | while IFS= read -r p; do
      case "$p" in
        */CACHEDIR.TAG) printf '%s\n' "${p%/CACHEDIR.TAG}"; continue ;;
      esac
      is=0
      if [ -e "$p/.rustc_info.json" ] || [ -e "$p/CACHEDIR.TAG" ]; then is=1; fi
      for f in "$p"/*/.fingerprint; do
        if [ -d "$f" ]; then is=1; break; fi
      done
      if [ "$is" -eq 1 ]; then printf '%s\n' "$p"; fi
    done
  return 0
}

# --- interrupt / failure cleanup (0.3.1) ----------------------------------------------
# A Ctrl-C'd cloud-only run left its 65 GB mktemp build dir — a staging copy of every
# secret — in $TMPDIR (2026-11-24): there was no trap. Now any non-zero exit after
# work began removes what it made: the stage, an unfinished archive, a half-copied
# destination file, and (cloud-only pick) the whole mktemp build dir. The success
# paths are unchanged (incl. "no cloud copy verified -> temp dir KEPT", rc 0).
_CLEAN_ARMED=0; _ARCHIVE_DONE=0; _COPY_TARGET=""; _TEMP_DIR=""; _SCRATCH=""
_on_exit() {
  local rc=$?
  # Removals FIRST, output LAST, errexit OFF: when the terminal itself went away (the
  # window closed, the pty died) every write fails, and under set -e the first failed
  # printf used to abort this handler before anything was removed (measured 2026-11-24).
  set +e
  if [ -n "$_TICK_PID" ]; then kill "$_TICK_PID" 2>/dev/null; wait "$_TICK_PID" 2>/dev/null; fi
  if [ -n "$_SCRATCH" ]; then rm -rf -- "$_SCRATCH"; fi
  if [ "$rc" -ne 0 ] && [ "$_CLEAN_ARMED" -eq 1 ]; then
    if [ -n "$_COPY_TARGET" ]; then rm -f -- "$_COPY_TARGET"; fi
    if [ -n "$_TEMP_DIR" ]; then
      rm -rf -- "$_TEMP_DIR"
    else
      if [ -n "${STAGE:-}" ]; then rm -rf -- "$STAGE"; fi
      if [ "$_ARCHIVE_DONE" -eq 0 ] && [ -n "${ARCHIVE:-}" ]; then rm -f -- "$ARCHIVE"; fi
    fi
    { if [ -n "$_TICK_PID" ]; then printf '\r\033[K'; fi
      printf '\n\033[1;33m⚠ backup stopped (exit %d) — its partial staging and archive were removed\033[0m\n' "$rc"
    } >&2 2>/dev/null
  fi
  _TICK_PID=""
  return "$rc"
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- destination menu gate -------------------------------------------------------
# No positional OUT AND both streams a terminal -> the interactive selector. The
# archive is built in the primary (first picked) destination; DESTS carries the full
# chosen set for Task 3's copies. Everything else (pipe, script, hook, explicit arg)
# takes exactly the pre-menu path.
DESTS="$OUT"
TEMP_BUILD=0
if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  DESTS="$(_choose_destinations "$OUT")" || exit 1
  OUT="${DESTS%%$'\n'*}"
  # 0.3.0 cloud semantics: a pick containing a CLOUD dir but NO local dir (the
  # default entry 1 or a custom path) builds the archive ONCE in a temp dir; each
  # chosen cloud dir then gets a sequential sha256-verified copy and the temp dir
  # is auto-removed after the first verified copy (kept + warned when none
  # verifies). A local pick is always kept — built in when it is the primary.
  _local_pick=""; _cloud_pick=0
  while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    if _is_cloud_dest "$_d"; then _cloud_pick=1; else _local_pick="$_d"; fi
  done <<< "$DESTS"
  if [ "$_cloud_pick" -eq 1 ] && [ -z "$_local_pick" ]; then
    TEMP_BUILD=1
    if [ "$DRY_RUN" -eq 1 ]; then
      OUT="(temp dir)"          # display only — a dry run writes nothing
    else
      OUT="$(mktemp -d "${TMPDIR:-/tmp}/mcm-build.XXXXXX")" || exit 1
      _TEMP_DIR="$OUT"; _CLEAN_ARMED=1   # an interrupt from here on removes the whole build dir
    fi
  fi
  STAGE="$OUT/stage-$STAMP"
  HOMEDIR="$STAGE/home"
  ARCHIVE="$OUT/claude-migration-$STAMP.tar.gz"
  printf 'Destinations: '
  _first=1
  while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    if [ "$_first" -eq 1 ]; then
      if [ "$TEMP_BUILD" -eq 1 ]; then printf '%s' "$_d"; else printf '%s (primary)' "$_d"; fi
      _first=0
    else printf ', %s' "$_d"; fi
  done <<< "$DESTS"
  printf '\n'
  if [ "$TEMP_BUILD" -eq 1 ]; then
    printf '   (cloud-only selection: archive built once in a temp dir, copied sha256-verified to each cloud dir, temp auto-removed after the first verified copy)\n'
  fi
fi

# Per-machine configuration, parsed BEFORE the dry-run exit so --dry-run shows the
# warning too (header documents the env vars / config files).
#   MIGRATION_REPOS / ~/.claude-migration-repos        git repos to record
#   MIGRATION_EXTRA_FILES / ~/.claude-migration-extra-files   extra files to capture
REPOS=()
COPIES=()
LISTFILE="$SRC/.claude-migration-repos"
if [ -n "${MIGRATION_REPOS:-}" ]; then
  # MIGRATION_REPOS overrides everything: no discovery, no prompts, no file
  # writes — exactly the pre-0.2.0 behaviour.
  IFS=: read -ra REPOS <<< "$MIGRATION_REPOS"
else
  # 0.2.0: the list file is built by discovery + merge (functions above).
  # Terminal runs ask (startup menu -> mode prompt -> review/no-remote menus);
  # non-terminal runs never prompt and park no-remote repos as `?` lines.
  _terminal=0
  if [ -t 0 ] && [ -t 1 ]; then _terminal=1; fi
  PREFSFILE="$SRC/.claude-migration-prefs"
  _filter=""        # "" keep all | "!+?" reset/change | "all" re-scan from scratch
  if [ "$RESET_CHOICES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    _write_pref repo_mode ""
    _filter="!+?"
    log "reset: remembered mode deleted — every !, + and ? entry will be asked again"
  fi
  # Remembered mode (validated; a malformed value is treated as absent).
  _mode="$(_read_pref repo_mode || true)"
  _mode_valid=0
  case "$_mode" in review|auto) _mode_valid=1 ;; esac
  # Does the list file carry any DECIDED line (?-parked lines are not decisions)?
  _list_decided=0
  if [ -f "$LISTFILE" ]; then
    if _read_repo_list "$LISTFILE" | grep -Eq $'^(record|exclude|copy)\t'; then _list_decided=1; fi
  fi
  _remembered_line="using remembered choices — reset with 'backup.sh --reset-choices' or the startup menu"
  # Startup menu: terminal, not a dry run, and remembered choices exist.
  if [ "$_terminal" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] \
     && { [ "$_mode_valid" -eq 1 ] || [ "$_list_decided" -eq 1 ]; }; then
    _MENU_ANS=""
    _startup_menu
    case "$_MENU_ANS" in
      change) _filter="!+?"; _mode_valid=0; _mode="" ;;  # re-ask the mode below
      rescan) _filter="all" ;;
    esac
    if [ -z "$_MENU_ANS" ]; then
      log "$_remembered_line"
    fi
  elif [ "$_mode_valid" -eq 1 ] || [ "$_list_decided" -eq 1 ]; then
    log "$_remembered_line"
  fi
  DISCOVERED=()
  _ticker_start "scanning your home folder for git repos" none
  _disc="$(_discover_repos)"
  _ticker_stop
  while IFS= read -r _d; do [ -n "$_d" ] && DISCOVERED+=("$_d"); done <<< "$_disc"
  # The filter turns !/+/? (reset/change) or every decision (re-scan) back into
  # new repos for THIS RUN, so the questions come back; the file is rewritten
  # after re-answering.
  _file_changed=0
  if [ -n "$_filter" ]; then
    _filtered=""
    while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      case "$_l" in
        comment$'\t'*) _filtered="${_filtered}${_filtered:+$'\n'}$_l" ;;
        record$'\t'*)  if [ "$_filter" = "all" ]; then continue; fi
                       _filtered="${_filtered}${_filtered:+$'\n'}$_l" ;;
        *)             : ;;   # exclude/copy/undecided: dropped, will be re-asked
      esac
    done <<< "$(_read_repo_list "$LISTFILE")"
    _merge_repos ${DISCOVERED[@]+"${DISCOVERED[@]}"} <<< "$_filtered"
    _file_changed=1
  else
    _merge_repos ${DISCOVERED[@]+"${DISCOVERED[@]}"} < <(_read_repo_list "$LISTFILE")
  fi
  # REPOS/COPIES carry only on-disk repos — a listed-but-missing path keeps its
  # line in the file (MERGE_LINES) and its warn, but is not "recorded".
  for _r in ${DECIDED_RECORD[@]+"${DECIDED_RECORD[@]}"}; do
    _merge_in_missing "$_r" || REPOS+=("$_r")
  done
  for _r in ${DECIDED_COPY[@]+"${DECIDED_COPY[@]}"}; do
    _merge_in_missing "$_r" || COPIES+=("$_r")
  done
  _appended=0
  # New repos WITH a remote: the mode decides (prompted when unknown), review
  # menu or automatic bare line.
  if [ "${#NEW_REMOTE[@]}" -gt 0 ]; then
    if [ "$_mode_valid" -eq 0 ]; then
      if [ "$_terminal" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        # _ask_repo_mode runs in the main shell (0.3.0): it writes the pref
        # itself on y AND its EOF redirect covers every later prompt.
        _ask_repo_mode
        _mode="$_MODE_ANS"
        _mode_valid=1
      else
        _mode="auto"     # non-terminal / dry-run: interim automatic, no prompts
      fi
    fi
    if [ "$_mode" = "auto" ] || [ "$_terminal" -eq 0 ]; then
      for _r in ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"}; do
        REPOS+=("$_r"); MERGE_LINES+=("record"$'\t'"$_r"); _appended=1
      done
    elif [ "$DRY_RUN" -eq 1 ]; then
      # A dry run NEVER prompts (design anti-goal) — say what the review list
      # would have offered instead of opening it.
      for _r in ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"}; do
        log "  dry run: would offer in the review list: $_r"
      done
    else
      _review_new_repos ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"} || exit 1
      for _r in ${NEW_REMOTE[@]+"${NEW_REMOTE[@]}"}; do
        _acc=0
        for _a in ${ACCEPTED[@]+"${ACCEPTED[@]}"}; do
          if [ "$_a" = "$_r" ]; then _acc=1; break; fi
        done
        if [ "$_acc" -eq 1 ]; then
          REPOS+=("$_r"); MERGE_LINES+=("record"$'\t'"$_r")
        else
          MERGE_LINES+=("exclude"$'\t'"$_r")   # review-reject: decided no; reset re-offers
        fi
        _appended=1
      done
    fi
  fi
  # No-remote repos — new ones AND parked `?` ones — get ONE batch menu on a
  # terminal (0.3.0): copy all / leave out all / decide one by one. Per-repo
  # answers land in the list file exactly as before, so the startup menu stays
  # the reuse-or-change point. Non-terminal / dry-run: new ones park as `?`.
  _nr_all=()
  for _r in ${NEW_NOREMOTE[@]+"${NEW_NOREMOTE[@]}"}; do _nr_all+=("$_r"); done
  if [ "$_terminal" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    for _r in ${DECIDED_UNDECIDED[@]+"${DECIDED_UNDECIDED[@]}"}; do _nr_all+=("$_r"); done
  fi
  if [ "${#_nr_all[@]}" -gt 0 ]; then
    if [ "$_terminal" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
      _ask_no_remote_batch ${_nr_all[@]+"${_nr_all[@]}"}
      _nr_ans="$_NRB_ANS"
      for _r in ${_nr_all[@]+"${_nr_all[@]}"}; do
        _dec=""
        case "$_nr_ans" in
          all)  _dec=copy ;;
          none) _dec=exclude ;;
          pick) _dec=exclude
                for _p in ${_NRB_PICK[@]+"${_NRB_PICK[@]}"}; do
                  if [ "$_p" = "$_r" ]; then _dec=copy; break; fi
                done ;;
          each) _ask_no_remote "$_r"
                _ans="$_NR_ANS"
                if [ "$_ans" = "copy" ]; then _dec=copy; else _dec=exclude; fi ;;
        esac
        _merge_drop_line undecided "$_r"   # a parked ? line is replaced by the decision
        if [ "$_dec" = "copy" ]; then
          COPIES+=("$_r"); MERGE_LINES+=("copy"$'\t'"$_r")
        else
          MERGE_LINES+=("exclude"$'\t'"$_r")
        fi
        _appended=1
      done
    else
      for _r in ${NEW_NOREMOTE[@]+"${NEW_NOREMOTE[@]}"}; do
        MERGE_LINES+=("undecided"$'\t'"$_r"); _appended=1
      done
    fi
  fi
  # Write the list file only when something changed (idempotent re-runs rewrite
  # nothing) and NEVER on --dry-run (a dry run writes nothing, ever).
  if { [ "$_appended" -eq 1 ] || [ "$_file_changed" -eq 1 ]; } && [ "$DRY_RUN" -eq 0 ]; then
    _merged=""
    for _l in ${MERGE_LINES[@]+"${MERGE_LINES[@]}"}; do _merged="${_merged}${_merged:+$'\n'}$_l"; done
    if [ -n "$_merged" ]; then _write_repo_list "$LISTFILE" "$_merged"; fi
  fi
  _n_listed=$(( ${#DECIDED_RECORD[@]} + ${#DECIDED_EXCLUDE[@]} + ${#DECIDED_COPY[@]} + ${#DECIDED_UNDECIDED[@]} ))
  if [ "${#DISCOVERED[@]}" -eq 0 ] && [ "$_n_listed" -eq 0 ]; then
    warn "no repos discovered under \$HOME and no list file — recording none"
  fi
  # Summary counts read the FINAL line set: recorded/copied are the on-disk
  # REPOS/COPIES arrays (missing entries count only as missing), excluded and
  # undecided count every remaining ! and ? line.
  _n_excl=0; _n_und=0
  for _l in ${MERGE_LINES[@]+"${MERGE_LINES[@]}"}; do
    case "${_l%%$'\t'*}" in
      exclude)   _n_excl=$((_n_excl + 1)) ;;
      undecided) _n_und=$((_n_und + 1)) ;;
    esac
  done
  log "repos: ${#REPOS[@]} recorded, ${#COPIES[@]} copied whole, $_n_excl excluded, $_n_und undecided, ${#MISSING[@]} missing"
  if [ "$_n_und" -gt 0 ]; then
    for _l in ${MERGE_LINES[@]+"${MERGE_LINES[@]}"}; do
      case "${_l%%$'\t'*}" in
        undecided) warn "  undecided (no remote): ${_l#*$'\t'}" ;;
      esac
    done
  fi
fi
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

_CLEAN_ARMED=1                         # from here a failure/interrupt removes the stage + partial archive
mkdir -p "$HOMEDIR" "$STAGE/repo-overlays"
_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mcm-scratch.XXXXXX")"   # exclude lists, pack log, ticker state

# Build-output excludes (0.3.1): one anchored --exclude-from list per rsync source.
_N_BUILD=0
_build_excludes() {  # _build_excludes <rel> <listfile> — write anchored excludes for <rel>, bump _N_BUILD
  local d n=0
  : > "$2"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '/%s/\n' "${d#./}" >> "$2"; n=$((n + 1))
  done <<< "$( cd "$SRC" && _build_output_dirs "$1" )"
  _N_BUILD=$((_N_BUILD + n))
  return 0
}
_tree_bytes() {  # _tree_bytes <rel> <exclude-list> — bytes of files under <rel> (from $SRC), listed dirs skipped
  local l
  local -a pr=()
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    l="${l#/}"; l="${l%/}"; pr+=(-o -path "$l")
  done < "$2"
  ( cd "$SRC" \
    && { find "$1" \( -name __mcm_never__ ${pr[@]+"${pr[@]}"} \) -prune -o -type f -print0 2>/dev/null || true; } \
    | { xargs -0 stat -f %z 2>/dev/null || true; } \
    | awk '{s += $1} END {printf "%d\n", s}' )
}
_CLAUDE_EXCL="$_SCRATCH/claude.exclude"
_build_excludes .claude "$_CLAUDE_EXCL"
# ~/.claude/backups (0.3.1, user decision): safety snapshots sessions write; build output
# inside is skipped anyway. A terminal run is asked once per run (size shown); a
# piped/scripted run keeps the old behaviour (included).
if [ -d "$SRC/.claude/backups" ] && [ -t 0 ] && [ -t 1 ]; then
  _ticker_start "measuring ~/.claude/backups" none
  _bk_bytes="$(_tree_bytes .claude/backups "$_CLAUDE_EXCL")"
  _ticker_stop
  _bk_ans=""
  while true; do
    printf '\n📦 ~/.claude/backups holds %s (safety snapshots; rebuildable build output inside is skipped anyway)\n' \
      "$(_human_bytes "${_bk_bytes:-0}")" >&2
    printf '   1) include it in the archive (Enter)\n' >&2
    printf '   2) leave it out of this backup\n\n' >&2
    _read_ans _bk_ans
    case "$_bk_ans" in
      ""|1) break ;;
      2)    printf '/.claude/backups/\n' >> "$_CLAUDE_EXCL"; log ".claude/backups left out of this backup"; break ;;
      *)    printf '  Unrecognized: %s\n' "$_bk_ans" >&2 ;;
    esac
  done
fi

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
# Vanish-tolerant wrappers (v0.3.0). On a LIVE machine the source tree changes
# WHILE a multi-minute backup runs: sessions rewrite ~/.claude, the
# waypoints-backups ring rotates its snapshots away, repos are edited
# concurrently. Measured 2026-11-23 — rsync exit 23 (`open (2) ... No such
# file or directory`) and tar `Cannot stat` each killed the WHOLE run under
# set -e. Contract: a file that vanished mid-run is warned and skipped; ANY
# OTHER error is still fatal.
_vanish_log_count() {  # _vanish_log_count <logfile> — print the vanished-notice
                       # count on stdout; rc 0 when EVERY line is vanished-class,
                       # rc 1 when a real error line exists (suppressed here; the
                       # caller prints the log once)
  local line n=0 bad=0
  while IFS= read -r line; do
    case "$line" in
      ''|*"No such file or directory"*|*"vanished"*|*"skipping non-regular file"*|*"Error exit delayed"*)
        n=$((n + 1)) ;;
      *)  bad=1 ;;
    esac
  done < "$1"
  printf '%s\n' "$n"
  [ "$bad" -eq 0 ]
}
_rsync_tolerant() {  # _rsync_tolerant <rsync args...> — vanished files warn+skip; real errors fatal
  local log rc n
  log="$(mktemp "${TMPDIR:-/tmp}/mcm-rsync-log.XXXXXX")" || return 1
  rc=0; rsync "$@" 2>"$log" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rc=0; rsync "$@" 2>>"$log" || rc=$?    # one retry: a vanished source is gone for good, a slow one may have copied
  fi
  if [ "$rc" -eq 0 ]; then rm -f -- "$log"; return 0; fi
  if n="$( _vanish_log_count "$log" 2>/dev/null )"; then
    warn "skipped $n file(s) that vanished mid-copy (live session rewrote them)"
    rm -f -- "$log"; return 0
  fi
  cat -- "$log" >&2
  printf '%s: rsync failed (exit %d) — aborting the backup\n' "${0##*/}" "$rc" >&2
  rm -f -- "$log"
  return 1
}
_tar_tolerant() {  # _tar_tolerant <out.tar.gz> <filelist> — run with cwd INSIDE the
                    # repo: filelist entries that already vanished are dropped with
                    # a warn, and a tar failure is tolerated only when every error
                    # line is vanished-class
  local out="$1" list="$2" kept log rc n line
  kept="$(mktemp "${TMPDIR:-/tmp}/mcm-tar-list.XXXXXX")" || return 1
  log="$(mktemp "${TMPDIR:-/tmp}/mcm-tar-log.XXXXXX")" || { rm -f -- "$kept"; return 1; }
  n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -e "$line" ]; then printf '%s\n' "$line" >> "$kept"; else n=$((n + 1)); fi
  done < "$list"
  if [ "$n" -gt 0 ]; then warn "  $n file(s) vanished before tar — skipped"; fi
  if [ ! -s "$kept" ]; then
    warn "  every listed file vanished — no tar written"
    rm -f -- "$kept" "$log"; return 0
  fi
  rc=0; tar czf "$out" -T "$kept" 2>"$log" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if n="$( _vanish_log_count "$log" 2>/dev/null )"; then
      warn "  tar skipped $n vanished file notice(s) during packing"
    else
      printf '%s: tar failed (exit %d) — aborting the backup\n' "${0##*/}" "$rc" >&2
      rm -f -- "$kept" "$log"; return 1
    fi
  fi
  rm -f -- "$kept" "$log"
  return 0
}
copy_rel() {  # copy_rel <relpath> [extra rsync args...]  — run from within $SRC
  local rel="$1"; shift
  [ -e "$SRC/$rel" ] || { warn "skip (missing): $rel"; return 0; }
  local xf
  xf="$(mktemp "$_SCRATCH/copy.exclude.XXXXXX")"
  _build_excludes "$rel" "$xf"
  ( cd "$SRC" && _rsync_tolerant -aR "${COMMON_EXCLUDES[@]}" --exclude-from="$xf" "$@" "$rel" "$HOMEDIR/" )
}

########################################################################
log "1/6  Claude Code state (.claude, minus redownloadable payloads/caches)"
########################################################################
# Keep everything in .claude EXCEPT plugin payloads/caches and pure runtime junk.
# We KEEP plugins/{installed_plugins,known_marketplaces}.json — the tiny manifest
# that tells restore.sh which marketplaces + plugins to reinstall.
# (Guarded like copy_rel: a fresh machine without .claude must not crash here.)
if [ -e "$SRC/.claude" ]; then
  _ticker_start "1/6 copying ~/.claude" none
  ( cd "$SRC" && _rsync_tolerant -aR "${COMMON_EXCLUDES[@]}" \
    --exclude-from="$_CLAUDE_EXCL" \
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
  _ticker_stop
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
  [ -e "$f" ] && ( cd "$SRC" && _rsync_tolerant -aR --no-specials --no-devices "$(basename "$f")" "$HOMEDIR/" )
done
# CAPTURED_WHOLESALE members are copied here (and pruned from discovery by the
# same list): one entry added to the variable is both copied and never walked.
for _cw in $CAPTURED_WHOLESALE; do
  case "$_cw" in .claude|.ssh) continue ;; esac   # .claude: copied above, minus redownloadables; .ssh: secrets step below
  copy_rel "$_cw"
done
copy_rel ".zshrc"
copy_rel ".zshrc.backup"
copy_rel ".gitconfig"
copy_rel ".zsh_history"
# Extra per-machine files, parsed up top (MIGRATION_EXTRA_FILES / the config file).
for f in ${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}; do copy_rel "$f"; done

########################################################################
log "3/6  Secrets & credentials (⚠️ sensitive)"
########################################################################
copy_rel ".ssh"                   # CAPTURED_WHOLESALE member: discovery prunes it (already archived here)
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
if [ "$_N_BUILD" -gt 0 ]; then
  note "    skipped $_N_BUILD dir(s) of rebuildable build output (cargo target/, CACHEDIR.TAG caches)"
fi

########################################################################
log "4/6  Git repos → record remote + exact commit + uncommitted overlay"
########################################################################
# These are all public. restore.sh clones them, checks out the RECORDED SHA
# (so you land on the same commit, not upstream HEAD), then applies an overlay
# of your uncommitted/untracked files (respecting .gitignore, so venvs are
# excluded automatically). This is "download from public source + zero gap".
# Repos were set up top (MIGRATION_REPOS, or discovered + merged into
# ~/.claude-migration-repos). COPIES (`+` lines) get a whole-tree tarball in
# Task 5; their repos.tsv row with an empty URL lands there too.
: > "$STAGE/repos.tsv"   # path<TAB>url<TAB>branch<TAB>sha
# bash-3.2 + set -u: an empty REPOS array must not crash here (the ${var+...} guard
# keeps the expansion empty instead of raising "unbound variable").
_REPO_STATE="$_SCRATCH/repo.state"; _ri=0; _rn="${#REPOS[@]}"
_SEEN_GITDIRS=""   # 0.3.1: unpushed commits are warned ONCE per repository, not per linked worktree
_ticker_start "4/6 repos" state "$_REPO_STATE"
for rel in ${REPOS[@]+"${REPOS[@]}"}; do
  _ri=$((_ri + 1)); printf '%d %d %s\n' "$_ri" "$_rn" "$rel" > "$_REPO_STATE"
  d="$SRC/$rel"
  # .git may be a DIRECTORY (normal repo) or a FILE (linked worktree) — both are roots
  [ -e "$d/.git" ] || { warn "not a git repo, skipping repo-mode: $rel"; continue; }
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
      _tar_tolerant "$STAGE/repo-overlays/$safe.tar.gz" "$STAGE/repo-overlays/$safe.filelist"
      note "    overlay: $rel ($(wc -l < "$STAGE/repo-overlays/$safe.filelist" | tr -d ' ') file(s))"
    fi )
  # Warn about unpushed commits — those are NOT on the remote, so cloning misses them.
  # `--branches` spans every local branch of the REPOSITORY, which all its linked
  # worktrees share — so the count is checked once per git-common-dir (0.3.1; one
  # repo with 20 worktrees used to print the same "52 UNPUSHED" 20 times).
  _gcd="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$d")"
  case "$_SEEN_GITDIRS" in
    *"|$_gcd|"*) : ;;
    *)
      _SEEN_GITDIRS="$_SEEN_GITDIRS|$_gcd|"
      unpushed="$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$unpushed" != "0" ]; then
        warn "  $rel has $unpushed UNPUSHED commit(s) across its local branches — push them before migrating!"
      fi ;;
  esac
done
_ticker_stop

# Whole-tree copies (`+` lines, 0.2.0): repos the user chose to copy whole —
# typically no-remote repos a clone could never bring back. Archived under
# repo-copies/<safe>.tar.gz (safe = tr / __): tracked + untracked files
# (gitignore-respected) PLUS the .git tree so the history comes along; the
# overlay's extra greps still apply, so a tracked node_modules cannot bloat it.
# The repos.tsv row carries an EMPTY URL — restore.sh extracts the tarball when
# it is present and keeps the "no remote" warning when it is not (old archives).
mkdir -p "$STAGE/repo-copies"
for rel in ${COPIES[@]+"${COPIES[@]}"}; do
  d="$SRC/$rel"
  [ -e "$d/.git" ] || { warn "not a git repo, skipping copy: $rel"; continue; }
  if [ -f "$d/.git" ]; then
    warn "  $rel is a linked worktree — its .git points into its main checkout; the copy may not be self-contained"
  fi
  safe="$(printf '%s' "$rel" | tr '/' '__')"
  sha="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '')"
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"
  printf '%s\t\t%s\t%s\n' "$rel" "$branch" "$sha" >> "$STAGE/repos.tsv"   # empty URL field
  ( cd "$d"
    { git -c core.quotepath=false ls-files -z -c -o --exclude-standard
      find .git -type f -print0
    } | tr '\0' '\n' \
      | grep -vE '(^|/)(\.venv|venv|node_modules|__pycache__)/' \
      | grep -vE '(^|/)\.DS_Store$' \
      | grep -v '^$' > "$STAGE/repo-copies/$safe.filelist" || true
    if [ -s "$STAGE/repo-copies/$safe.filelist" ]; then
      _ticker_start "4/6 whole-tree copy: $rel" none
      _tar_tolerant "$STAGE/repo-copies/$safe.tar.gz" "$STAGE/repo-copies/$safe.filelist"
      _ticker_stop
      note "    whole-tree copy: $rel ($(wc -l < "$STAGE/repo-copies/$safe.filelist" | tr -d ' ') file(s) incl. .git)"
    fi )
done

########################################################################
log "5/6  Reinstall manifests (public toolchain — recorded, not packaged)"
########################################################################
if command -v brew >/dev/null 2>&1; then
  _ticker_start "5/6 recording Homebrew packages" none
  if brew bundle dump --file="$STAGE/Brewfile" --force >/dev/null 2>&1; then
    _ticker_stop; note "    Brewfile: $(grep -c . "$STAGE/Brewfile") entries"
  else
    _ticker_stop; warn "brew bundle dump failed"
  fi
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
- `repo-copies/`           — whole-tree copies (incl. `.git`) of no-remote repos
                             the user chose to copy (`+` lines in the list);
                             restore.sh extracts them when repos.tsv has an
                             empty URL for the row.
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
# 0.3.1: tar -v lists one line per entry on stderr; the ticker counts that log
# against the stage's entry count for a live bar. A tar failure stays fatal and
# prints its real error lines (the "a <path>" listing is filtered out).
_PACK_LOG="$_SCRATCH/pack.log"
_pack_total="$(find "$STAGE" | wc -l | tr -d ' ')"
_pack_t0="$(date +%s)"
_ticker_start "packing" count "$_PACK_LOG" "$_pack_total"
_prc=0; tar czvf "$ARCHIVE" -C "$STAGE" . 2>"$_PACK_LOG" || _prc=$?
_ticker_stop
if [ "$_prc" -ne 0 ]; then
  grep -v '^a ' "$_PACK_LOG" >&2 || true
  printf '%s: tar failed packing the archive (exit %d) — aborting\n' "${0##*/}" "$_prc" >&2
  exit 1
fi
chmod 600 "$ARCHIVE"
_ARCHIVE_DONE=1
note "    packed $_pack_total entries → $(_human_bytes "$(stat -f %z "$ARCHIVE")") in $(_fmt_elapsed $(( $(date +%s) - _pack_t0 )))"

# Copy the finished archive to every additional chosen destination, size-verified.
# A failed convenience copy warns and never fails the backup — the primary exists.
# Single-destination runs (piped/scripted/positional-arg) skip all of this and the
# DONE line stays byte-identical to the pre-menu shape.
_DEST_SUFFIX=""
_VERIFIED_CLOUD=0
_KEPT_ARCHIVE=""
_src_sum=""        # 0.3.1: hashed ONCE (it used to be re-read in full for every destination)
_arch_bytes="$(stat -f %z "$ARCHIVE")"
_n_dest=0; _i_dest=0
while IFS= read -r _d; do [ -n "$_d" ] && [ "$_d" != "$OUT" ] && _n_dest=$((_n_dest + 1)); done <<< "$DESTS"
while IFS= read -r _d; do
  [ -z "$_d" ] && continue
  if [ "$_d" != "$OUT" ]; then
    _i_dest=$((_i_dest + 1))
    _target="$_d/$(basename "$ARCHIVE")"
    if [ -z "$_src_sum" ]; then
      _ticker_start "sha256 of the archive" none
      _src_sum="$(shasum -a 256 -- "$ARCHIVE" 2>/dev/null | awk '{print $1}')" || _src_sum=""
      _ticker_stop
    fi
    # The default destination may not exist yet when it is a SECONDARY (the primary
    # is created by the main flow) — the user picked it, so create it. mkdir is INSIDE
    # the guarded if: under set -euo pipefail a bare failing mkdir would abort the whole
    # script; here an uncreatable target simply lands in the warn branch.
    # Copies run SEQUENTIALLY and are verified byte-accurate (sha256, not just size).
    _COPY_TARGET="$_target"            # an interrupt mid-copy removes the half-written file
    _ticker_start "copy $_i_dest/$_n_dest → ${_d##*/}" size "$_target" "$_arch_bytes"
    _cprc=1
    if { [ -d "$_d" ] || mkdir -p -- "$_d" 2>/dev/null; } && cp -p -- "$ARCHIVE" "$_target" 2>/dev/null; then
      _cprc=0
    fi
    _ticker_stop
    if [ "$_cprc" -eq 0 ]; then
      _ticker_start "verifying copy $_i_dest/$_n_dest (sha256)" none
      _dst_sum="$(shasum -a 256 -- "$_target" 2>/dev/null | awk '{print $1}')" || _dst_sum=""
      _ticker_stop
      if [ -n "$_src_sum" ] && [ "$_src_sum" = "$_dst_sum" ]; then
        log "copied → $_target (sha256 verified)"
        if _is_cloud_dest "$_d"; then
          _VERIFIED_CLOUD=$((_VERIFIED_CLOUD + 1))
          [ -z "$_KEPT_ARCHIVE" ] && _KEPT_ARCHIVE="$_target"
        fi
      else
        warn "copy to $_d is NOT byte-accurate (sha256 mismatch) — removed, skipped"
        rm -f -- "$_target" 2>/dev/null || true
      fi
    else
      rm -f -- "$_target" 2>/dev/null || true
      warn "could not copy to $_d (skipped) — the primary archive is intact"
    fi
    _COPY_TARGET=""
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

# 0.3.0: a temp build dir exists only when a cloud-only pick was made; it is
# removed ONLY after at least one cloud copy verified byte-accurate. The rm
# target is exclusively the mktemp dir captured in $OUT above — never a picked path.
if [ "$TEMP_BUILD" -eq 1 ]; then
  if [ "$_VERIFIED_CLOUD" -gt 0 ]; then
    rm -rf -- "$OUT"
    log "temp build dir removed — a byte-accurate (sha256) copy is verified in the cloud"
    ARCHIVE="$_KEPT_ARCHIVE"
  else
    warn "no cloud copy verified — the temp build dir is KEPT: $OUT (archive: $ARCHIVE)"
  fi
fi

SIZE="$(du -sh "$ARCHIVE" | cut -f1)"
echo
log "DONE. Archive: $ARCHIVE  ($SIZE)${_DEST_SUFFIX}"
warn "This archive contains SECRETS. Move it to the new Mac over AirDrop/USB, not cloud."
echo "Next: copy restore.sh + this archive to the new Mac, then run:"
echo "    bash restore.sh \"$ARCHIVE\""
