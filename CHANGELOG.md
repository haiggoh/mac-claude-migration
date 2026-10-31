# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims at
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version in `VERSION`
is the single source; this file's top entry must agree (pinned by
`tests/test_portability.sh`).

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
