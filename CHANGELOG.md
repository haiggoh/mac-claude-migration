# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims at
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version in `VERSION`
is the single source; this file's top entry must agree (pinned by
`tests/test_portability.sh`).

## [0.2.0] — 2026-11-10

### Added — repo auto-discovery (user spec, 2026-11-09)

- With `MIGRATION_REPOS` unset, `backup.sh` now builds its repo list itself: it scans
  `$HOME` (pruned: `~/Library`, cloud dirs, caches, `node_modules`/`.venv`/`venv`/
  `__pycache__`, the default output dir, and everything the archive already captures
  wholesale), finds every repo root (`.git` directory OR linked-worktree file, depth
  ≤ 4, nested repos suppressed), and merges the result with
  `~/.claude-migration-repos`. A user who just presses Enter gets every repo they
  work in.
- List-file line prefixes: bare = record, `!` = excluded (never offered again),
  `+` = copy the whole tree (incl. `.git`) into `repo-copies/`, `?` = undecided
  (parked by a non-terminal run, asked on the next terminal run), `#` = comment.
  Writes are atomic (temp + `mv`); user comments and line order are preserved.
- Terminal runs ask only what mcm cannot decide alone, and remember every answer:
  a startup menu (carry on / change / re-scan from scratch), a review-vs-automatic
  mode prompt (remembered in `~/.claude-migration-prefs`), a pre-ticked review list
  (toggle by number, `a`/`n`, Enter), and a per-repo menu for no-remote repos that
  shows the size the copy would add. Non-terminal runs never prompt (EOF aborts
  like `q`).
- `--reset-choices` forgets the remembered answers and re-asks on that run (needs a
  terminal; exit 2 without one; announces only under `--dry-run`). The same reset is
  reachable from the startup menu. `--dry-run` runs discovery + merge and prints the
  pinned summary but never prompts and writes nothing.
- Run summary line: `repos: N recorded, N copied whole, N excluded, N undecided,
  N missing` (undecided/missing named on following warn lines).
- `restore.sh`: a `repos.tsv` row with an empty URL *and* a matching `repo-copies/`
  tarball is extracted to `$HOME/<path>` (skipped with a message when the destination
  already exists). Rows without a tarball keep the old "no remote — skipping"
  warning, so pre-0.2.0 archives restore unchanged.

### Fixed

- Pre-existing 0.1.5 defect exposed by the new old-archive test: `restore.sh` read
  `repos.tsv` with `IFS=$'\t' read`, which collapses consecutive tabs — an empty-URL
  row shifted every later field left and read `url=branch` ("git clone master
  proj"). Fields are now split manually.

### Tests

- 9 suites, `tests/run-all.sh` → ALL SUITES PASSED, all hermetic (fake HOMEs, local
  remotes, stubbed brew/pipx, pty with paced keys): + `test_discovery` (33),
  `test_repo_list` (14), `test_flow` (8), `test_prompts` (21), `test_repo_copies`
  (7), `test_e2e` (7). Every task mutation-checked (RED line shown, then restored);
  QC milestones (a)+(b) reviewed by an out-of-family dispatch (18 PROVEN / 2 WEAK,
  both fixed with mutation proof).

## [0.1.5] — 2026-11-08

### Added — 🍺 Homebrew install

- `brew install haiggoh/tap/mac-claude-migration` puts `mac-claude-backup` and
  `mac-claude-restore` on your PATH (formula merged in haiggoh/homebrew-tap PR #20).
  The tap's hourly `bump-formulas.yml` repoints the formula at each new release
  automatically, so `brew upgrade mac-claude-migration` keeps the commands current.
- README gains the brew install line above the direct `./backup.sh` usage.

## [0.1.4] — 2026-11-05

### Fixed — destination-menu hardening (deferred-review polish)

- A 20-digit (or ≥6-digit) answer token now re-asks instead of slipping past the
  range check (bash `[` errors on the overflow and the old code read that as
  "valid"); the resolution index could then abort the subshell. Pinned by case 34
  (mutation-checked).
- The `*`-answer pin is now DISCRIMINATING: the pty child cwd's into the fake HOME,
  so a planted digit-named directory would be a real glob hit without `set -f`.
- New end-to-end pin: a SPACE-NAMED cloud root selected through the menu (the path
  travels menu → DESTS → archive, spaces intact).
- Test pacing: an initial 1 s sleep before the first keystroke (the one race that
  ate input in flat probes); suites remain hermetic and fast (run-all ≈45 s).

## [0.1.3] — 2026-11-05

### Added — 📦 interactive destination-selection menu (user spec, modelled on the iphone-backup tool)

- A bare `backup.sh` on a terminal opens a branded destination selector: detected cloud
  roots (`~/Library/CloudStorage/*`, legacy `~/Dropbox`/`~/OneDrive`, iCloud Drive) plus
  the default output directory (shown first, with its path). Multi-select
  (`1 3` / `1,3`, `a` = all listed, `Enter`/`d` = default) or a custom directory
  (`c`, with a `[y/N]` confirm before `mkdir`; `--dry-run` only announces it).
- The archive is always **built in the primary** (first picked) destination, then copied
  — byte-size-verified — to every additional chosen destination; a failed copy warns and
  never fails the backup. The DONE line lists all destinations on multi-dest runs.
- `--list-destinations` prints the candidates as `path<TAB>label` (machine-readable),
  exits before any work.
- Piped, scripted, cron and explicit-directory runs never open the menu — byte-identical
  to before (pinned). Pure bash 3.2 throughout; `tests/test_destinations.sh` (34 cases,
  pty-driven menu tests included) is registered in `run-all.sh`.
- Also fixed: the portability suite's real-run test now runs against a fake HOME
  (it was packaging the developer's live home — slow and flaky under session writes).

## [0.1.2] — 2026-11-03 — 📦 branding lands on the public-release lineage

- **Added:** the emoji-rollout Task 21 branding — 📦 leads both scripts'
  `--help` banner and the README h1, pinned by `tests/test_branding.sh`.
  It had shipped to `main` on 2026-10-31, but the release lineage forked
  before it, so v0.1.0/v0.1.1 published without the marks. This release
  reconciles the two lineages.
- **Fixed:** `usage()`'s dynamic-awk header range printed the bare `#`
  separator as `--help`'s first line (a merge artifact of combining the
  branding banner with the 0.1.0 usage rewrite) — it now skips leading
  empty comment lines so the banner is the first line again.

## [0.1.1] — 2026-10-31 — post-release council review fixes

- **Fixed:** a real `backup.sh` run with NO repos configured crashed under `/bin/bash`
  3.2 (`set -u` + empty `REPOS` array: "REPOS[@]: unbound variable") — found by the
  cross-family council review after 0.1.0 shipped; the 0.1.0 portability test only
  exercised `--dry-run`, which exits before that loop. `tests/test_portability.sh` now
  runs a real `/bin/bash` run with an empty config and asserts an archive is produced.
- **Fixed:** the overlay `git ls-files` now emits NUL-separated paths re-expanded to
  lines with `core.quotepath=false`, so filenames with non-ASCII or special characters
  are no longer shell-quoted into the tar list.
- **Fixed:** `restore.sh`'s symlink rewrite uses a literal prefix test instead of a
  `case` glob pattern, so a source home containing glob characters (`[`, `]`, `*`)
  cannot mis-route a rewrite.
- **Fixed:** the `.claude` rsync leg is guarded like `copy_rel` — a machine without
  `~/.claude` (fresh Mac) no longer crashes the backup with an rsync lstat error
  (found by the new real-run test, not by 0.1.0's dry-run-only coverage).
- Not changed: the installed `bin` wrapper's mode is `0555` by Homebrew's own post-install
  (council flagged the `.write` as non-executable; verified `0555` on the installed copy).

## [0.1.0] — 2026-10-31 — first public release: machine-agnostic

### Changed
- `backup.sh`: the git-repo list and the extra-file list are no longer hardcoded —
  configure per machine via `MIGRATION_REPOS` / `MIGRATION_EXTRA_FILES` (colon-separated,
  relative to `$HOME`) or `~/.claude-migration-repos` / `~/.claude-migration-extra-files`
  (one per line). Unset records none and warns. The source user/home/tool version are
  written to `meta.env` in the archive.
- `restore.sh`: reads `meta.env` and rewrites absolute-path symlinks that point into
  the source home to the new `$HOME`, so a different username on the new Mac works.
  Steps 4–5 no longer hardcode specific repos/tools: virtualenvs and node deps are
  recreated for every repo in `repos.tsv`, and every package in `pipx-list.txt` is
  reinstalled. No source-machine username or hardcoded paths remain in the scripts.
- `usage()` in both scripts prints the whole header comment block (dynamic awk range
  instead of a fixed line range).

### Added
- `VERSION` + this `CHANGELOG.md`; `tests/test_portability.sh` pins: zero machine-specific
  path/username hits in the scripts, `VERSION` == CHANGELOG top entry, both scripts parse
  under bash 3.2, and `backup.sh --dry-run` works with an empty fake HOME.
- README: "Configure what gets captured" section for a fresh machine.
