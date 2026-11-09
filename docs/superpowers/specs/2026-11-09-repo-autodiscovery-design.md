# Repo auto-discovery for backup.sh — design

Date: 2026-11-09 · Status: draft for review · Target version: 0.2.0

## Why

Since 0.1.0 removed the hardcoded repo list, `backup.sh` records git repos only
when the user has set `MIGRATION_REPOS` or hand-written `~/.claude-migration-repos`.
Without either, it prints one warning ("no repos configured … recording none") and
produces an archive whose `repos.tsv` is empty, so `restore.sh` re-clones nothing.
The run still succeeds. This happened on the author's own machine: 34 repos were
silently dropped from every backup since 0.1.0.

Expecting a user to notice that warning, work out what it means, and hand-write a
list of their repos is the bug. **mcm must build the list itself.** It asks the
user only for what it cannot know, and asks each thing once.

## Goals

- When no list file exists (first run, or the file was deleted), discovery runs
  automatically. No flag or setup is needed.
- Discovery is complete enough that a user who just presses Enter gets every repo
  they work in.
- Questions are asked only where mcm cannot decide alone, and every answer can be
  remembered so later runs do not ask again.
- Each remembered choice can be undone, both from the terminal and from scripts.
- Repos created after the list was made get picked up on later runs.

## Non-goals

- Backing up repo contents that are re-downloadable. The REINSTALL philosophy in
  the `backup.sh` header still holds: a repo with a remote is recorded as
  URL + SHA + uncommitted overlay, never copied.
- Discovering repos outside `$HOME` (other volumes, `/opt`, `/usr/local`).
- Changing how `MIGRATION_EXTRA_FILES` works.

## Anti-goals (a failure even if it technically works)

- **A scripted run that hangs** waiting for input. Any non-terminal run must
  never prompt.
- **A run that triggers cloud downloads or crawls for minutes.** Walking into
  `~/Library/CloudStorage`, iCloud Drive or Dropbox can force dataless files to
  download. Discovery must never enter them.
- **Silently dropping a repo again.** Any repo that was found but not recorded
  must be named in the run summary, with the reason.
- **Asking the same question every run.**
- **`--dry-run` writing anything or prompting.** The existing portability test
  pins "fresh-machine --dry-run writes nothing".

## Constraints

- `/bin/bash` 3.2 compatible, same as the rest of the script: no associative
  arrays, no `${var,,}`, and an empty array under `set -u` must not crash
  (`${arr[@]+"${arr[@]}"}`).
- Menu chrome goes to stderr, and only results go to stdout. This is the
  established convention of `_choose_destinations`.
- The terminal gate is the existing one: prompts happen only when `[ -t 0 ] && [ -t 1 ]`.
- Archives made by older `backup.sh` versions must still restore with the new
  `restore.sh`.
- `MIGRATION_REPOS`, when set, keeps overriding everything. When it is set there
  is no discovery, no prompts and no file writes.

## Decided by the user

1. **Scan scope:** all of `$HOME`, to a depth limit, with prunes (list below).
2. **Repos with no remote:** asked about once per repo in a terminal menu, with
   two answers: *copy the whole tree into the archive*, or *leave it out*. The
   answer is saved.
3. **Confirm vs. automatic:** on the first run, ask which mode the user wants:
   *review a pre-ticked list of found repos*, or *carry on automatically*. Then
   ask whether to remember that choice for future runs.
4. **Later runs:** every run re-scans. Repos new since the list was made are
   offered (review mode) or added (automatic mode). Repos the user excluded stay
   excluded.
5. **Reset:** both of the following.
   - A flag, `backup.sh --reset-choices`, forgets the remembered answers and asks
     again on that run.
   - On terminal runs, a startup menu entry: carry on with the remembered
     settings, change them, or re-scan from scratch.
   Any run that uses a remembered choice prints one line saying so and naming
   both ways to reset it.

## Behaviour

### Where the state lives

- **`~/.claude-migration-repos`** stays the list. It stays hand-editable, and
  existing files keep working: a bare line `path` (relative to `$HOME`) means
  *record*. New line prefixes:
  - `!path`: excluded by the user, never offered again.
  - `+path`: no remote; copy the whole tree into the archive.
  - `?path`: found by a non-terminal run but still undecided (no remote, nobody
    asked yet). Not recorded. The next terminal run asks about it.
  - `#`: comment. A generated file starts with a short comment header that
    explains these prefixes and the reset options.
- **`~/.claude-migration-prefs`** holds the remembered settings as `key=value`
  lines, starting with `repo_mode=review|auto` (absent means "ask"). The
  key=value format leaves room for later keys.

### The run, step by step

Repo setup runs after the destination menu and before the `--dry-run` exit. It
replaces the block at `backup.sh:255-266`.

1. If `MIGRATION_REPOS` is set, use it and skip everything below. (Same as today.)
2. **Discover** repo roots under `$HOME`. A root is any directory containing
   `.git`, whether that is a directory or a file. The file case is a linked
   worktree, e.g. `~/ClaudeWorkspace/.wt/*`, which today's `[ -d "$d/.git" ]`
   check wrongly rejects. Do not descend into a repo root, so nested repos and
   submodules are not listed separately.
3. **Prune**, i.e. never enter:
   - `~/Library` (this covers CloudStorage, Mobile Documents and caches)
   - `~/Dropbox` and `~/OneDrive`
   - `~/.Trash` and `~/.cache`
   - `~/.npm`, `~/.cargo`, `~/.rustup` and `~/go/pkg`
   - any `node_modules`, `.venv`, `venv` or `__pycache__`
   - the default output dir `~/claude-migration`
   - **every path the archive already captures wholesale**: `.claude` (which
     holds the plugin cache and the local-only `~/.claude/plans` git repo, both
     already covered by step 1/6), `.claude-flow`, `.joyia` and `.ssh`. Derive
     this list from the same source as the copy steps, so it cannot drift from
     them.
4. **Classify** each found root: has a remote (`origin`, else the first remote),
   or no remote.
5. **Merge with the list file:**
   - paths already present with any prefix are *decided*;
   - paths listed but no longer on disk produce a warning ("listed repo missing:
     …") and stay in the file;
   - everything else is *new*.
6. **Decide new repos:**
   - With a remote: review mode puts them in the pre-ticked list; automatic mode
     adds them as bare lines.
   - Without a remote, in a terminal: the per-repo menu (copy / leave out). It
     shows each repo's size (gitignored files excluded), because that is what a
     copy adds to the archive.
   - Without a remote, no terminal: write `?path` and name it in the summary.
7. **Mode prompt** (terminal only, when no `repo_mode` is remembered or after a
   reset): review or automatic, then "remember this for future runs? [y/N]".
8. **Startup menu** (terminal only, when remembered choices exist): Enter =
   carry on with the remembered settings; `c` = change them (re-ask the mode
   prompt, and allow re-deciding excluded and copied repos); `r` = re-scan from
   scratch (ignore the list file's decisions for this run, then rewrite the
   file).
9. **Write** the list file atomically (temp file + `mv`) whenever anything
   changed. Preserve the user's own comment lines and line order. Append new
   entries at the end.
10. **Summary line** in the run output: N recorded, N copied whole, N excluded,
    N undecided (named), N listed-but-missing (named).

### `--reset-choices`

Deletes `repo_mode` from the prefs file and turns every `!`, `+` and `?` line
back into undecided for this run, so the questions come back. It needs a
terminal. In a non-terminal run it exits 2 with a message saying so, rather than
silently doing nothing. *My call:* the alternative was silently "un-excluding"
repos with nobody there to answer.

### `--dry-run`

Runs discovery and the merge, and prints what would be recorded, copied,
excluded or asked about. It never prompts and writes nothing. The
fresh-machine test still passes. Its "warns when no repos configured" assertion
changes to assert the new discovery summary instead. The no-repos warning stays
only for the case where discovery itself finds zero repos.

### Whole-tree copies (`+path`) in the archive and on restore

- **backup:** archive the repo's tracked and untracked files, minus gitignored
  ones, **plus its `.git` directory**, so the history comes along. Store it under
  `repo-copies/<safe>.tar.gz`. List these in `repos.tsv` with an empty URL, as
  today, so the existing uv/npm resync loop covers them too.
- **restore:** when a `repos.tsv` row has an empty URL *and* a matching
  `repo-copies/` tarball, extract it to `$HOME/<path>`. Skip it with a message if
  the destination already exists. Rows with no tarball keep today's
  "no remote — skipping" warning, which is what makes old archives restore
  unchanged.

## Left to the builder

- The depth limit. It must reach `~/ClaudeWorkspace/.wt/<name>` (depth 3), and
  discovery must finish in under ~10 s on a home of this size. Measure, don't
  guess.
- The menu grammar for the pre-ticked list (toggle by number, `a` = all,
  `n` = none, Enter = accept). Follow `_choose_destinations` conventions.
- How linked worktrees restore. *My call (tentative):* treat them like any other
  repo with a remote, i.e. clone + SHA + overlay to the worktree's path, so no
  uncommitted work is lost. The builder may propose recreating them as real
  worktrees of their main repo if that is clean.
- Test layout. Every new behaviour gets a case in `tests/`, run under
  `/bin/bash` 3.2. A non-terminal run must be proven not to prompt, e.g. by
  running with stdin from `/dev/null` and a timeout.
- Version bump to 0.2.0 on every version surface (`VERSION`, CHANGELOG, README).
