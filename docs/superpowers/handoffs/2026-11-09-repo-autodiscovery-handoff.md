# Handoff — repo auto-discovery for backup.sh (mcm 0.2.0)

Written 2026-11-09 ~02:30 CET by a paid Claude Opus 5.5 session, handed over at the
user's request (`/free-agents:free-session-handover max effort glm flash`).

## 1. Why this handoff exists

The user asked for the work to move to a free GLM 5.3 Flash session at max effort.
Nothing crashed. The previous session ended at the design stage:

- the design doc is written;
- the builder check was dispatched, but **every free dispatch lane failed** at
  ~02:15–02:25 CET (Gemini HTTP 503; Mistral Large 4, DeepSeek V4.1 Flash,
  GLM 5.3 Flash and Step 5 Preview all timed out on NVIDIA; the 600 s wall cap
  was hit). So no builder-check result exists yet.

NVIDIA was timing out across the board at handover. If your own turns stall on 429s
or timeouts, that is upstream, not a bug to diagnose.

## 2. State

- Repo: `~/ClaudeWorkspace/mac-claude-migration` (mcm). Branch:
  **`feat/repo-autodiscovery`**, cut from `main` @ `4a9bb4f` (0.1.5).
- This branch has one commit: this handoff + the design doc (see `git log -1`).
- Baseline tests, run 2026-11-09 under `/bin/bash` (3.2), all PASS:
  - `test_branding` 3
  - `test_capture_shapes` 10
  - `test_cli_contract` 15
  - `test_destinations` 37
  - `test_portability` 10

  Run them all with `tests/run-all.sh`.
- Design (READ IT FULLY):
  `docs/superpowers/specs/2026-11-09-repo-autodiscovery-design.md`.
- No plan exists yet.

## 3. The goal, verbatim (user, 2026-11-09)

> "no, that's terrible. we can't expect users to notice this error and deduct that
> they have to handroll a list of their repos before mcm works properly. mcm needs
> to be able to make that list itself and if it's missing information only the
> user can provide it should ask for it interactively. but mainly I want this to be
> an automatic process on the first run (and every subsequent run that for some
> reason doesn't find the file)"

The user's design answers are recorded in the design doc under "Decided by the user":
- scan all of `$HOME`, pruned;
- ask once per repo with no remote;
- offer review vs. automatic, then ask whether to remember the choice;
- re-scan and offer new repos;
- reset via BOTH a `--reset-choices` flag AND a terminal startup-menu entry.

Those are binding. Everything marked "my call" or under "Left to the builder" is
yours to settle, with a recorded reason.

**Approval caveat:** the user had not yet formally approved the design doc when they
handed over. Treat the "Decided by the user" section as approved scope. Any genuine
"only the user can answer this" question goes into §6 Open questions with your
tentative call. Do not stop for it.

## 4. Standing rules (adopt for the whole session)

1. Autonomous: decide and record instead of asking; stop only for forks that cannot
   be weighed.
2. Work only in `~/ClaudeWorkspace/mac-claude-migration` on `feat/repo-autodiscovery`.
   Never switch branches there; if you need isolation, make a worktree.
3. Commit every milestone, staged **by path** (never `git add -A` / `git add .`).
   Trailers:
   ```
   Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
   ```
   followed by the running model's verbatim trailer from memory
   `commit-attribution-by-model` (GLM 5.3 Flash; check your identity first).
   Push the branch when the plan is fully green. **Never merge, tag or release.**
4. TDD every change: the test fails for the right reason, then passes.
   Mutation-check each new guard. Never weaken a test to get green. The one
   sanctioned test change: `test_portability.sh` case 4 asserts the old
   "no repos configured" warning; update it to the new discovery summary, as the
   design says.
5. Review each milestone with an independent dispatch:
   ```
   python3 ~/ClaudeWorkspace/free-agents/bin/free-agent-tool.py \
     <<< '{"prompt": ..., "files": [...]}'
   ```
   Check every finding against the real code: reviewers hallucinate file names.
   If all lanes fail, do a documented self-review and say so in the progress log.
6. Resolve model and roster facts when you need them, from the catalog, never from
   memory.
7. Never run `remote-session.sh --stop`, never start another remote session, and
   never kill anything listening on 4141–4151: one of them is the proxy you run on.
8. Record progress in §7 of this doc at each milestone, in the same commit.
9. If you are told to "hand off to a new session", YOU are that successor. Continue
   this doc directly. Never launch another session.
10. mcm specifics:
    - `/bin/bash` 3.2 compatible: no associative arrays, no `${v,,}`, and empty
      arrays guarded as `${a[@]+"${a[@]}"}`.
    - Menu chrome goes to stderr.
    - Prompts only when `[ -t 0 ] && [ -t 1 ]`.
    - A non-terminal run must never prompt. Prove it with stdin `</dev/null` plus
      a timeout (macOS has no `timeout`: use `perl -e 'alarm N; exec @ARGV'`).
    - Menu grammar (user rule): numbers = actions, `q`/`b` = Quit/Back.
    - Every new flag appears in `--help`; verify by RUNNING `backup.sh --help`.
    - NEVER walk into `~/Library`, CloudStorage, iCloud, Dropbox or OneDrive: it
      can trigger cloud downloads.
    - Run real (non-dry) backups only against a fake `HOME` in a temp dir. A real
      run on the real home writes a tarball full of secrets.
11. Version: bump to 0.2.0 on every version surface (`VERSION`, `CHANGELOG.md`,
    README, any other place `grep -rn 0.1.5` finds).

## 5. Next action

1. **Builder check:** re-dispatch it once. The prompt is in
   `~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.0/skills/brainstorming/builder-check-prompt.md`
   (domain = "bash / macOS shell-tooling engineer"; files = the design doc,
   `backup.sh`, `restore.sh`). If the lanes still fail, do the builder read
   yourself. Sort the questions:
   - answered already → write the answer into the design;
   - minor → settle it and mark it "builder's call";
   - only-the-user → §6 below, with your tentative call.

   Commit the updated design.
2. **Plan:** write the implementation plan with `superpowers:writing-plans` at
   `docs/superpowers/plans/2026-11-09-repo-autodiscovery.md`. Its header names
   `superpowers:executing-plans`, so the executor does every task itself plus one
   final review.

   **REQUIRED (user, 2026-11-09 02:31):** the plan applies the playbook
   `~/.claude/plans/_playbooks/Playbook-milestone-qc-offload-test-proof.md`. Read
   it in full. The plan gets a "Quality-control milestones" section with 3–6 named
   milestones. Each milestone lists its requirements, with the design/plan wording
   copied verbatim, and the test files that cover them. Copy the playbook's
   standing rule into the plan verbatim, along with its dispatch brief. Suggested
   milestones (adjust to the real task split):
   - **(a) Discovery walk + prunes.** Linked-worktree `.git` file; nested repos not
     listed; `~/Library` / CloudStorage / `.claude` never entered (prove it with a
     planted repo in each).
   - **(b) List-file merge.** Bare / `!` / `+` / `?` / `#` lines; user comments and
     order preserved; atomic write; listed-but-missing warning.
   - **(c) Prompts.** A non-terminal run never prompts (stdin `</dev/null` +
     alarm); the mode prompt + remember; the startup menu; `--reset-choices`,
     including its exit 2 without a terminal.
   - **(d) Whole-tree copy.** The backup tarball includes `.git`, minus ignored
     files; `restore.sh` extracts it; an OLD archive with no `repo-copies/` still
     restores unchanged.
   - **(e) Pre-ship.** The full fake-HOME end-to-end run from step 4.

   Shell-suite adaptation of the playbook's "`pytest -rs`" rule: the receipt shows
   each test script's ok/bad counts and confirms that no case was skipped or
   short-circuited.

   Commit.
3. **Execute** the plan natively with `superpowers:executing-plans`, task by task,
   with TDD and a progress line here after each task. At each QC milestone, run
   the playbook dispatch. Use an out-of-family reviewer, i.e. NOT GLM: pick the
   strongest other free lane from `free-agent-tool.py --list`. Then:
   - apply every proposed mutation and show its RED run line;
   - restore, and confirm `git diff` is empty for the mutation;
   - write the milestone receipt into §7.

   Never start the next task with an open finding.
4. Full gate: `tests/run-all.sh` all green, `backup.sh --help` shows the new flag,
   and a fake-HOME end-to-end run. The fake HOME holds:
   - a repo with a remote;
   - a repo with no remote;
   - a linked worktree;
   - a repo under a pruned path;
   - a repo under `.claude`.

   The run proves that discovery, the `?`/`+`/`!` lines, the copy tarball and
   `restore.sh` extraction all work. Push the branch. Stop.

## 6. Open questions for the user (fill in; do not block on them)

- (none yet)

## 7. Progress log (append one line per milestone)

- 2026-11-09 02:30 — design drafted, builder check failed on all lanes, handed over
  (Opus 5.5).
