# 📦 mac-claude-migration

Move a whole Claude Code setup to a new Mac: **package what cannot be
redownloaded, reinstall everything that can.**

## Install

```sh
brew install haiggoh/tap/mac-claude-migration
# puts mac-claude-backup and mac-claude-restore on your PATH;
# the tap's hourly auto-bump keeps the formula on the newest release,
# so `brew upgrade mac-claude-migration` is all the updating you do
```

No Homebrew (or prefer the scripts)? Clone this repo and run them directly:

```console
$ ./backup.sh --dry-run          # show what would be captured, write nothing
$ ./backup.sh                    # interactive: destination menu (see below)
                                  # piped/scripted: -> ~/claude-migration/claude-migration-<stamp>.tar.gz
$ ./backup.sh /some/dir          # writes into /some/dir, menu stays shut
$ ./backup.sh --list-destinations   # machine-readable candidate list, exit 0
$ ./restore.sh <archive.tar.gz>  # on the new Mac
$ ./tests/run-all.sh
ALL SUITES PASSED
```

## Choosing destinations (interactive menu)

On a terminal, a bare `backup.sh` opens a destination selector (modelled on the
iphone-backup tool): it detects the common cloud-provider roots
(`~/Library/CloudStorage/*`, plus legacy `~/Dropbox`/`~/OneDrive` and iCloud Drive),
shows the default output directory first with its path, and lets you pick **several
destinations at once** (`1 3` or `1,3`; `a` = all listed; `Enter` = default only) or a
custom directory (`c`, with a confirm before any `mkdir`). The archive is always built
in the primary (first picked) destination and then copied — size-verified — to each
additional one; a failed copy warns and never fails the backup. Piped, scripted, cron
and explicit-directory runs never open the menu and behave exactly as before.

## What it captures, and what it deliberately does not

**Packaged** — local-only state with no other source: session transcripts, memory,
settings and hooks, the `.claude.json` project map, the plugin *selection*
manifest, dotfiles, and secrets.

**Reinstalled, not copied** — anything public: Homebrew formulae, git repos
(recorded as remote + exact SHA, plus an overlay of your uncommitted work),
virtualenvs, `node_modules`, pipx tools, plugin *payloads*, the Claude binary.
Recording a version is smaller and more honest than shipping a stale copy.

## ⚠️ The archive contains secrets

SSH keys, API keys, a `gh` token. It is written `chmod 600`. Transfer it by
AirDrop, USB, or another encrypted channel — never email or a cloud paste. This
repo's `.gitignore` refuses `*.tar.gz` so an archive cannot be committed by
accident: the scripts belong in git, the payload never does.

## Tests, and why they exist

`tests/run-all.sh` covers two things that actually broke:

**CLI contract.** Both scripts once mishandled `--help`. `backup.sh --help`
*ignored the flag and started the backup*; `restore.sh --help` read `--help` as
an archive filename, printed `archive not found: --help`, and exited **0** — a
failed probe that looked successful. Now arguments are parsed before any work, an
unknown flag exits non-zero from the parser, and the tests assert the script's own
diagnostic rather than accepting an incidental downstream failure.

**Capture shapes.** `~/.api_keys` changed from a single sourceable file into a
directory of one-secret-per-file. The rsync leg kept working (`rsync -a` is
recursive) but a `cp` without `-r` would have silently dropped it, and the
scripts' own documentation went stale — including a restore verification step that
would now always fail and make a good restore look broken. These tests replay the
real copy against a fake `$HOME`, assert `700`/`600` modes survive both legs, and
fail if the docs drift back.

Both suites were **mutation-tested**: run against the pre-fix scripts they report
9 failures. A suite that cannot fail proves nothing, so that check is the point.

## Configure what gets captured (per machine)

Extra files are **not** hardcoded:

```sh
export MIGRATION_EXTRA_FILES="projects/notes.md"          # extra files to capture
```

or put one path per line in `~/.claude-migration-extra-files` (`#` comments ok).

**Git repos are discovered automatically (0.2.0).** With `MIGRATION_REPOS` unset,
`backup.sh` scans `$HOME` (pruned — never enters `~/Library`, cloud-sync dirs,
caches, `node_modules`/`.venv`, the output dir, or anything the archive already
captures), finds every repo (including linked worktrees), and merges them into
`~/.claude-migration-repos`. On a terminal it asks only what it cannot decide
alone — the mode (review vs automatic), and what to do with no-remote repos — and
remembers each answer. On scripts/pipes it never prompts: no-remote repos are
parked as `?` lines and asked on the next terminal run.

The list file stays hand-editable, one path per line (`#` comments ok):

- `path` — record: remote + exact commit + uncommitted overlay on restore
- `!path` — excluded, never offered again
- `+path` — copy the whole tree (incl. `.git`) into the archive (`repo-copies/`)
- `?path` — undecided (found without a remote on a non-terminal run)

To forget all remembered answers and be asked again: `bash backup.sh
--reset-choices`, or choose it in the startup menu on a terminal run.
`MIGRATION_REPOS="a:b"` (colon-separated, relative to `$HOME`) still overrides
everything — no discovery, no prompts, no file writes.

The source user/home are stored in the archive's `meta.env`, and `restore.sh`
rewrites absolute-path symlinks that pointed into the source home to the new
`$HOME` — so the username may differ between the machines.

## Requirements & assumptions

`bash` (3.2-compatible — the `/bin/bash` macOS ships), `rsync`, `git`, `tar`.
The scripts use `$HOME` throughout and carry no machine-specific paths; the
username may differ between source and target Macs (see above). Restore needs
Homebrew (`brew bundle` leg); without it the script says so and continues.

## License

MIT
