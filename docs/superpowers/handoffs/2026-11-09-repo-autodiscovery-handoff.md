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
- Branch commits (2026-11-09): `49636c2` (this doc + §5 amendment), `819ad6c`
  (design doc + builder-check self-review), `7f93da5` (implementation plan),
  `01ba1f6` (plan Task 1: discovery engine, 33/33 tests). Working tree clean.
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
- 2026-11-09 03:52 — baseline re-verified (run-all.sh ALL SUITES PASSED); §5.1
  builder-check re-dispatch timed out on all four remote lanes (Gemini/Mistral/
  DeepSeek V4.1/Step 5), so the builder read was done by this session per rule 5:
  10 settled calls appended to the design, none user-blocking. Dispatch model-role
  filters dropped for this session (user, 03:42); identity confirmed from the session
  envelope (z-ai/glm-5.3-flash), trailer taken from the attribution table since the
  project memory dir is empty (GLM 5.3 Flash).
- 2026-11-09 04:0x — §5.2 plan written with superpowers:writing-plans +
  run-to-completion:writing-execution-plans (authority matrix, Phase 0, receipts,
  discriminants) and the REQUIRED milestone-QC section (playbook standing rule +
  brief verbatim; milestones (a)–(e); role filters dropped per user; self-review
  fallback named for lane outages). Self-reviewed: spec coverage, step scan, type
  consistency, review focus, proportion.
- 2026-11-09 08:56 — Task 1 discovery walk: 33/33 new suite cases (RED first:
  extraction barrier fired), run-all ALL SUITES PASSED (rc 0; 14+9+9+3+36+33),
  real-HOME walk 1.57 s / 91 repo roots → maxdepth 5 stands (ledger ruling).
  Mutation: dead Library prune → exactly 2 targeted REDs, byte-identical
  restore (cmp). Notes: run-all invokes suites BY PATH, so a new suite needs
  +x (the Write tool omits it); the first two receipts' rc readings came from
  a grep pipe, not the suite — re-captured un-piped.
- 2026-11-09 ~12:35 — QC milestone (a) dispatch: every remote lane timed out
  again (Gemini read-timeout, Mistral 900 s budget), then the dispatch CRASHED
  in the tool itself: the no-role run reaches a `remote openrouter` fallback
  entry whose `timeout` is null → `entry.get("timeout", 1800)` returns None →
  `TypeError: min(None, int)` at `free-agents/bin/free-agent-tool.py:586`
  (waypoint filed 🧭). Per rule 5 the milestone got a DOCUMENTED SELF-REVIEW
  instead: every discovery case carries a positive control (a control repo
  found in the same run) except pure-empty cases, which are gated by the
  suite-level extraction barrier; the semantic Library-prune mutation above
  is the discriminant receipt (2 targeted REDs, cmp-verified restore). Verdict:
  milestone (a) PROVEN by suite + mutation; an independent dispatch verdict
  was UNAVAILABLE (lanes down + tool bug) — rerun one dispatch when lanes
  recover, before relying on the milestone.
- 2026-11-09 ~14:57 — handed over AGAIN at the user's request
  (`/free-agents:free-session-handover max effort`): successor launched on
  `nvidia-glm53` @ max effort with this doc as the initial prompt; this session
  (A) deliberately NOT stopped (rule 7 — never kill the band). Position at
  handover: Task 1 complete @ `01ba1f6`; plan Task 2 (list-file I/O + merge)
  is next — its failing tests are NOT yet written; one ruling is ledgered in
  `.superpowers/sdd/2026-11-09-repo-autodiscovery/progress.md` (git-ignored but
  on disk: read it first — `_read_repo_list` gains a `comment` state so user
  comments survive rewrites). Secret scan of all touched files: clean (0/6).
- 2026-11-09 ~18:2x — Task 2 list-file I/O + merge complete: `_read_repo_list` /
  `_write_repo_list` / `_merge_repos` (+ `_merge_decided`) added to backup.sh after
  `_repo_remote`; `tests/test_repo_list.sh` 14/14 (RED first: extraction barrier
  fired), `tests/run-all.sh` ALL SUITES PASSED rc 0 (14+9+9+3+36+33+14). Comment state
  carries verbatim lines per the ledger ruling (lossless rewrite, cmp-proven);
  atomic write proven by an inode-change case (temp+mv, not direct write).
- 2026-11-09 ~18:3x — Task 2 discriminants, both shown RED then restored (git
  status clean, backup cmp-identical): (1) CR-strip dropped → first SURVIVED
  GREEN (the [[:space:]] trim absorbs a trailing CR on path lines), so the
  suite was strengthened with a CRLF COMMENT line whose verbatim payload must
  come back CR-free → mutation then RED (`FAIL comment state`, 13/1, rc 1);
  (2) direct `> "$file"` instead of temp+mv → RED on the atomic case (inode
  unchanged) AND on header-on-create (the redirect creates the target before
  the `[ ! -e ]` test runs, suppressing the header — the temp name is what
  keeps the check honest): `FAIL atomic write` + `FAIL header`, 12/2, rc 1.
- 2026-11-09 ~19:2x — Task 3 flow wiring complete: old repos block replaced by
  discovery→merge→append→write-if-changed→summary (MIGRATION_REPOS keeps old
  verbatim behaviour; dry-run never writes; interim treats all runs as automatic
  and parks no-remote repos as `?`); portability case 4 updated to the sanctioned
  `repos:` summary assertion; `tests/test_flow.sh` 7/7 (RED first: 1/6 on old
  code). Two real bugs caught mid-task: `[ -d .git ]` rejects worktree FILEs in
  BOTH the merge and the git-loop guard (→ `[ -e ]`), and listed-but-missing
  repos leaked into the "recorded" count (REPOS/COPIES now filter via
  `_merge_in_missing`; the file line and warn are kept). Non-terminal proof:
  stdin </dev/null + perl alarm, rc 0.
- 2026-11-09 ~21:5x — QC milestone (b) DISPATCH SUCCEEDED (lanes recovered):
  gemini-3.8-flash via remote gemini (out-of-family, avoid_family=zhipu honoured);
  verdict table 18 PROVEN / 2 WEAK / 0 UNPROVEN. Every mutation it proposed for a
  PROVEN row was already covered (e.g. -type d -name .git, unconditional write,
  -d vs -e in merge). The 2 WEAK findings FIXED and mutation-proven:
  (1) header CONTENT unasserted → test_repo_list case 6 now greps the header for
  --reset-choices and the !/+/? prefix lines; (2) warning gate listed==0 half
  untested → new test_flow case 6 (list holds only a missing `!gone` entry,
  0 repos on disk): warning suppressed, line kept, file untouched; the
  reviewer's own mutation (drop `&& [ "$_n_listed" -eq 0 ]`) now goes RED
  (`FAIL warning gate`, 7/1) then restored → green. This dispatch also covers
  milestone (a)'s pending rerun — its requirements (items 1–4: worktree .git
  file, nested suppression, per-prune cases with controls, depth boundary) all
  PROVEN. Suites after fixes: repo_list 14/14, flow 8/8.
- 2026-11-09 ~23:5x — Task 4 prompts/menus/prefs/--reset-choices complete:
  `_read_pref`/`_write_pref` (atomic, empty value deletes), `_repo_size`,
  `_ask_repo_mode`, `_startup_menu`, `_ask_no_remote`, `_review_new_repos`,
  `_merge_drop_line`; flag parse + usage() line + reset gate (non-terminal or
  MIGRATION_REPOS ⇒ exit 2; dry-run announces only); flow gains terminal
  branches (startup menu before discovery, mode prompt when new-remote repos
  exist and no mode remembered, review menu gates bare lines, per-repo menu
  replaces interim `?`, parked `?` re-asked on terminal). `tests/test_prompts.sh`
  20/20 (RED first: 0/20). Builder rulings in the SDD ledger (mode prompt only
  when NEW_REMOTE non-empty; review-reject → `!path`; change drops !+ and
  re-asks mode; re-scan drops all decisions; reset drops !+? + repo_mode).
  Two real bugs caught: BRE vs ERE grep silently skipped the startup menu;
  _WRITE_MODE subshell loss (remember=y never wrote prefs) — pref write moved
  into _ask_repo_mode. Discriminant: terminal-gate dropped from the mode-prompt
  path → non-terminal proof RED (rc 1 via EOF abort, 18/2) → restored.
- 2026-11-10 ~04:4x — Task 5 whole-tree copies implemented (backup copy loop +
  repos.tsv empty-URL rows + MANIFEST line; restore extraction branch with
  dest-exists skip; `tests/test_repo_copies.sh` 7/7, RED first 0/7). BOTH
  discriminants shown RED then restored: .git tree dropped → copy-tarball +
  restore cases RED (4/3); dest-exists check dropped → skip case RED (6/1,
  sentinel clobbered). PRE-EXISTING 0.1.5 DEFECT found + fixed by the
  old-archive case: `IFS=$'\t' read` collapsed consecutive tabs so an
  empty-URL row read url=branch → "git clone master proj"; restore now splits
  TSV fields manually. Also: bsdtar -C needs the target dir to exist; tr is
  1:1 (a/b→a_b, same as 0.1.x overlays). **CHECKPOINT — wrap requested
  mid-task:** suite receipts all in (repo-copies 7/7; full gate re-run ALL
  SUITES PASSED rc 0, 14+9+9+36+33+14+8+20+7) but Task 6 is NOT started.
  Next session must (1) Task 6 (VERSION 0.2.0 + CHANGELOG + README +
  tests/test_e2e.sh + full gate + `grep -rn 0\.1\.5`), (2) push the branch
  (gated on the full gate), never merge/tag/release. Worktree `+` copies warn
  that their .git file points into the main checkout (documented limitation).
- 2026-11-10 ~11:2x — ADVERSARIAL SELF-REVIEW (user-requested) found and fixed one
  real bug the suites had missed: a pty --dry-run with remembered
  repo_mode=review OPENED THE REVIEW MENU on a new remote repo and aborted on
  EOF — violating "dry-run never prompts". Fix: review branch gated on
  DRY_RUN=0 (dry-run announces "would offer in the review list" instead);
  pinned by new test_prompts.sh case 17 (RED: menu opened + rc 1 → GREEN:
  no banner, rc 0, files untouched; 21/21). Call-site audit: all 5 prompt
  sites now carry terminal+dry-run gates; write paths too. Also verified
  live: --help documents --reset-choices and writes nothing; the
  --list-destinations probe still wins over --reset-choices (rc 0);
  dry-run on empty HOME prints the pinned summary and writes nothing;
  VERSION/CHANGELOG still consistently 0.1.5 (Task 6 pending by design);
  the --help header's stale "warned below" line fixed (bad741f). Fresh
  full gate on the final tree: see final commit.
- 2026-11-10 ~12:3x — Task 6 complete: VERSION 0.2.0 + CHANGELOG top entry +
  README repo-discovery section (auto-discovery, prefixes, both reset ways,
  --reset-choices) + tests/test_e2e.sh (five-part fake HOME: run 1 non-terminal
  bare/?/pruned-absent + TOOL_VERSION=0.2.0 pin (RED until the bump), run 2 pty
  with seeded +/! lines → copy tarball + remembered-choices line, restore →
  clone at recorded SHA + extraction with .git + excluded absent). Discriminant:
  VERSION reverted to 0.1.5 → portability case 2 RED → restored. Full gate with
  10 suites: see the Task 6 commit. Then push the branch (gated on green) and
  STOP — no merge/tag/release (rule 3). One observed flake: a single e2e run-2
  pty failure before the 1.5 s pacing hardening; 3 subsequent runs 7/7 (pacing
  now matches the measured test_destinations pattern).
- 2026-11-10 ~13:0x — Task 6 committed (5a00053) and the branch PUSHED:
  `git ls-remote origin feat/repo-autodiscovery` → 5a00053f6b57… ✓. Full gate
  green before push (ALL SUITES PASSED, 10 suites). STOPPED here per rule 3 —
  no merge, no tag, no release, no tap bump (separate repo). Plan COMPLETE:
  all 6 tasks + QC milestones (a),(b) + adversarial review done.
- 2026-11-10 ~13:4x — QC milestones (c)(d)(e): the out-of-family dispatch HUNG
  (gemini 503 → Mistral Large 4 stuck >30 min, no fall-over), so per handoff
  rule 5 the milestone got a DOCUMENTED SELF-REVIEW instead. Verdict: (d) and
  (e) PROVEN by their suites (repo_copies 7/7 incl. old-archive + tracked-.venv
  + space paths; e2e 7/7 incl. TOOL_VERSION pin + restore-at-SHA). (c) had ONE
  gap the review caught: no test pinned that startup-menu "change" (2/c)
  re-decides an EXCLUDED repo (only re-scan 3/r was pinned) → added
  test_prompts case 18 (passes: change filter drops ! lines, auto re-records
  bare) → prompts 22/22. An independent dispatch verdict for (c)(d)(e) was
  UNAVAILABLE (lanes down again) — rerun one dispatch when lanes recover.
