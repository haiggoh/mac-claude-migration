# mac-claude-migration

Move a whole Claude Code setup to a new Mac: **package what cannot be
redownloaded, reinstall everything that can.**

```console
$ ./backup.sh --dry-run          # show what would be captured, write nothing
$ ./backup.sh                    # -> ~/claude-migration/claude-migration-<stamp>.tar.gz
$ ./restore.sh <archive.tar.gz>  # on the new Mac
$ ./tests/run-all.sh
ALL SUITES PASSED
```

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

## Requirements & assumptions

`bash` (3.2-compatible — the `/bin/bash` macOS ships), `rsync`, `git`, `tar`.
Restore assumes the **same username** on both machines, so absolute-path symlinks
resolve unchanged; the code itself uses `$HOME` throughout.

## License

MIT
