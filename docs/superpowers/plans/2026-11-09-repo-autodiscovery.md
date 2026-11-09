# Repo auto-discovery for backup.sh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use **superpowers:executing-plans** to implement this plan task-by-task (the executor does every task itself, plus one final review — chosen by the handoff, not open). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `backup.sh` builds its repo list itself — scanning `$HOME` (pruned), asking only what it cannot know, remembering every answer — so a user who just presses Enter gets every repo they work in.

**Architecture:** Four new functions in `backup.sh` (`_discover_repos`, list-file read/merge/write, prompt/menu set) replace the block at `backup.sh:255-266`; `+` entries add whole-tree tarballs under `repo-copies/` and a matching extraction branch in `restore.sh`. State stays in two hand-editable files: `~/.claude-migration-repos` (prefixed lines) and `~/.claude-migration-prefs` (`key=value`).

**Tech Stack:** `/bin/bash` 3.2 (macOS), BSD `find`, `git`, `tar`; tests are plain bash suites under `tests/`, pty-driven via `script -q /dev/null`.

**Spec:** `docs/superpowers/specs/2026-11-09-repo-autodiscovery-design.md` (read it fully — the plan argues from it; its §Builder check records ten settled calls this plan relies on).

## 🚨 System instructions for the executor — read first

1. This plan is self-contained; do not depend on a previous chat. Revalidate live source and tool schemas before any mutation.
2. Before the first file edit, output exactly three strategy sentences connecting the first phase to the final outcome; then run the read-only Phase 0 preflight.
3. Prefer native read/search/edit tools; use the shell for version control, tests and execution. Do not guess tool schemas, rewrite files from fragments, or ship placeholder code.
4. Respect the authority matrix. **Never merge, tag or release; never push before the full gate; never run a real (non-dry) backup against the real `$HOME`.**
5. A task is done only with its receipt; a failure means STOP, diagnose, fix, rerun, and show both runs. Every new guard gets a mutation check (RED line shown, then restored, `git diff` empty).
6. No secrets in logs or receipts (fake HOMEs only). Say "not tested" when a check cannot safely run.

## 📌 Context and objectives

**Project:** `~/ClaudeWorkspace/mac-claude-migration` (mcm), branch `feat/repo-autodiscovery`. Entry points: `backup.sh` (repos block `255-266`, git loop `386-407`), `restore.sh` (repos loop `116-139`). Line numbers are *dated observations* from 0.1.5 — re-check with Read before anchoring edits.

**Current → required:** without `MIGRATION_REPOS` or a hand-written `~/.claude-migration-repos`, a run warns "no repos configured" and records nothing → discovery builds the list automatically; undecidable cases prompt (terminal) or park (`?`, non-terminal); every answer is remembered and resettable (`--reset-choices` + startup menu); `+` repos are copied whole (with `.git`) and restored by extraction.

**Evidence labels:** *live* = re-verified this session (baseline suites ALL PASSED on 0.1.5; only version surfaces are `VERSION` + `CHANGELOG.md`). *decision* = design §Builder check calls 1–10. *unknown to inspect* = exact line anchors at execution time.

**Hard constraints:** bash 3.2 only (no assoc arrays, no `${v,,}`, `${a[@]+"${a[@]}"}`); menu chrome → stderr; prompts only when `[ -t 0 ] && [ -t 1 ]`; a non-terminal run never prompts; old archives still restore; `MIGRATION_REPOS` set ⇒ no discovery, no prompts, no file writes; never walk into `~/Library`, CloudStorage, iCloud, Dropbox, OneDrive.

**Acceptance criteria:** handoff §5.4 full gate — `tests/run-all.sh` green, `--help` shows `--reset-choices`, the five-part fake-HOME e2e proves discovery, `?`/`+`/`!` lines, copy tarball and restore extraction. Deferred: merge/tag/release (prohibited), tap formula update (separate repo).

## 🔒 Authority matrix

| Operation | Status | Evidence or gate |
|---|---|---|
| Read-only inspection, running tests | Allowed now | source check |
| Edit + commit (staged **by path**) on `feat/repo-autodiscovery` | Allowed now | tests green; never `git add -A` |
| Push branch `feat/repo-autodiscovery` | **Gated** on full gate green | handoff §5.4 "Push the branch. Stop." |
| Merge / tag / release / bump the tap | **Prohibited** | handoff rule 3 |
| Free-lane dispatch (stateless, no `role` filter — user 2026-11-09 03:42) | Allowed now | `free-agent-tool.py`, any available lane |
| Paid dispatch / any spend | **Prohibited** without separate user approval | costs money |
| Real (non-dry) backup on real `$HOME`; killing processes; ports 4141–4151 / 8000–8010 | **Prohibited** | writes a secrets tarball / kills this session's proxy |
| Network in tests (brew/uv/npm/clone-over-HTTPS) | **Prohibited** — stub `brew` on PATH, local-path remotes, fake HOME | hermetic tests |

## 🛑 Phase 0 — forced preflight

**Objective:** correct branch, clean tree, green baseline, tool facts.
1. Three strategy sentences (see system instructions 2).
2. Read-only: `git branch --show-current` (= `feat/repo-autodiscovery`), `git status --porcelain` (empty; if not, back up per the global rule BEFORE editing), `/bin/bash --version` (3.2), `git --version`, `tests/run-all.sh` (ALL SUITES PASSED).
3. Re-read the design doc + the exact `backup.sh`/`restore.sh` regions this plan anchors on (line numbers above are dated).
**🧪 Receipt 0:** branch name, empty porcelain, baseline `ALL SUITES PASSED`, bash version — quoted.

## Global Constraints (spec, verbatim values)

- `/bin/bash` 3.2 compatible; empty arrays guarded `${a[@]+"${a[@]}"}` (design §Constraints).
- Menu chrome → stderr; results/warnings via existing `log()`/`warn()` (stdout) — design Builder call 9.
- Prompts only when `[ -t 0 ] && [ -t 1 ]`; EOF at any prompt aborts like `q` (never spins on a closed pipe).
- Menu grammar (user rule): numbers = actions/entries, `q`/`b` = Quit/Back; special letters per settled call 1.
- New flags appear in `--help` (verified by RUNNING `backup.sh --help`).
- Archives from older versions must still restore (restore change is additive only).
- Depth limit 4; walk budget ~10 s (settled call 5).
- Summary line format (pinned for tests): `repos: N recorded, N copied whole, N excluded, N undecided, N missing` — undecided/missing named on following `warn` lines when non-zero.

## Quality-control milestones (playbook: `~/.claude/plans/_PLAYBOOKS/Playbook-milestone-qc-offload-test-proof.md`)

Standing rule for the executor, verbatim: *"At each milestone, run /offload (free-agents:offload) — a stateless dispatch to an out-of-family reviewer — with the brief below. Treat its findings as hypotheses: run every proposed mutation; fix or rebut each finding with evidence. Do not start the next task with an open finding."*

**Reviewer selection:** out-of-family from the writing model (GLM / zhipu) → strongest available **non-zhipu** lane from `free-agent-tool.py --list`. Model-**role** filters are dropped this session (user, 2026-11-09 03:42) — pass no `role`. If every lane fails, do a **documented self-review** (handoff rule 5) and say so in §7 of the handoff — a *paid* check needs separate user approval and is not authorized.

**Dispatch brief (verbatim from the playbook; attach files via `"files"` — a dispatch cannot read the disk):**

```
You are reviewing TESTS, not code style. Attached: the plan task text (requirements), the test file(s),
the fixtures, and the implementation.
For EACH requirement:
 1. Quote the assertion(s) that prove it. None → say "UNPROVEN".
 2. Could every test still pass with the requirement unmet? Describe the smallest code mutation that
    would break the requirement yet leave the suite green.
 3. Fixture check: does the fixture actually contain the shape the requirement is about (the edge
    value, the failing upstream, the second item, the unicode, the space in the path)? If not, what
    must it contain?
 4. Is the assertion on the OUTCOME (state on disk, rendered output, argv actually executed) or on a
    proxy (a mock was called, exit code 0, no exception)?
Also flag: skips/xfails, fakes that copy the implementation's logic, tests that assert on the fake.
Output: a table requirement → verdict (PROVEN / WEAK / UNPROVEN) → mutation → fixture fix.
```

**Executor duties after each dispatch (playbook, abridged):** apply every proposed mutation in isolation (temp edit, never a live file) → suite must go RED (show the RED run line); an un-applied mutation "reports caught" is a pitfall — verify it landed; restore until `git diff` is empty for the mutation; strengthen weak fixtures; re-run until RED then green. **Shell-suite adaptation of "`pytest -rs`":** the receipt quotes each test script's `N passed, M failed` line and confirms no case was skipped or short-circuited (case count = ok+bad lines; our harness has no skip mechanism).

### Milestones

**(a) Discovery walk + prunes** — after Task 1.
Requirements (design §Behaviour 2–3 + settled calls 5–6, verbatim): "A root is any directory containing `.git`, whether that is a directory or a file. The file case is a linked worktree… Do not descend into a repo root, so nested repos and submodules are not listed separately." Prunes: `~/Library`, `~/Dropbox`, `~/OneDrive`, `~/.Trash`, `~/.cache`, `~/.npm`, `~/.cargo`, `~/.rustup`, `~/go/pkg`, `node_modules`/`.venv`/`venv`/`__pycache__` anywhere, `~/claude-migration`, and "every path the archive already captures wholesale… Derive this list from the same source as the copy steps, so it cannot drift from them." Depth = 4 (reaches `~/ClaudeWorkspace/.wt/<name>`); nested roots suppressed by ancestor post-filter.
Tests: `tests/test_discovery.sh` (incl. a repo planted under EACH pruned path — proves non-entry).

**(b) List-file merge + flow wiring** — after Tasks 2–3.
Requirements (design §Where the state lives, §5 Merge, §9 Write, §10 Summary, §--dry-run, §Constraints; settled calls 2–4, 8–9): bare = record; `!` excluded-never-offered; `+` copy whole; `?` undecided non-terminal; `#` comment; generated header explains prefixes + resets; decided paths kept; "listed repo missing: …" warning, line kept; atomic write (temp + `mv`), user comments and order preserved, new entries appended; `MIGRATION_REPOS` set ⇒ "no discovery, no prompts and no file writes"; `--dry-run` runs discovery + merge, prompts and writes nothing; no-repos warning only when discovery finds zero AND list empty; summary line format above; `~`-prefixed and trailing-`/` input lines normalized; CR stripped from read lines.
Tests: `tests/test_repo_list.sh`, updated `tests/test_portability.sh` case 4 (the one sanctioned test change — asserts the discovery summary instead of "no repos configured").

**(c) Prompts + reset** — after Task 4.
Requirements (design §6 Decide, §7 Mode prompt, §8 Startup menu, §--reset-choices; settled call 1; anti-goals): non-terminal run **never prompts** (prove: stdin `</dev/null` under a `perl -e 'alarm N; exec @ARGV'` timeout); mode prompt review/automatic then "remember this for future runs? [y/N]"; startup menu Enter|`1` = carry on, `2`/`c` = change, `3`/`r` = re-scan from scratch, `q` = abort; per-repo no-remote menu copy/leave-out showing repo size (gitignored excluded); review list pre-ticked, toggle by number, `a` = all, `n` = none, Enter = accept; remembered choice in use ⇒ one line naming both reset ways; `--reset-choices` needs a terminal, else exit 2 with a message; under `MIGRATION_REPOS` exit 2 (no file write); under `--dry-run` announce without writing.
Tests: `tests/test_prompts.sh`.

**(d) Whole-tree copy + restore** — after Task 5.
Requirements (design §Whole-tree copies, verbatim): "backup: archive the repo's tracked and untracked files, minus gitignored ones, **plus its `.git` directory**… Store it under `repo-copies/<safe>.tar.gz`. List these in `repos.tsv` with an empty URL"; restore: "when a `repos.tsv` row has an empty URL *and* a matching `repo-copies/` tarball, extract it to `$HOME/<path>`. Skip it with a message if the destination already exists. Rows with no tarball keep today's 'no remote — skipping' warning, which is what makes old archives restore unchanged." Copy exclusions: `.gitignore`-respected + overlay's extra greps + `.DS_Store` (settled call 7).
Tests: `tests/test_repo_copies.sh` (backup side + restore side with a `brew` PATH stub + local-path remote + old-archive shape).

**(e) Pre-ship full gate** — after Task 6.
Requirements (handoff §5.4): `tests/run-all.sh` all green; `backup.sh --help` shows `--reset-choices`; fake-HOME e2e holding a repo with a remote, a repo with no remote, a linked worktree, a repo under a pruned path, a repo under `.claude` — proving discovery, the `?`/`+`/`!` lines, the copy tarball and `restore.sh` extraction.
Tests: `tests/test_e2e.sh` + quoted receipt in the handoff §7.

## Review Focus (spec-implied inputs no single task test pins)

1. **Spaces / glob metachars in repo paths** — discovery, menus and tarball naming must survive `My Drive` and `repo[1]`; expect intact paths end-to-end. (Pinned: discovery + repo-copies tests.)
2. **`.git` as a FILE at depth ≤ 4** (linked worktree) — must be found; a `.git` file deeper than the limit is a documented miss, not a crash. (Pinned: discovery tests.)
3. **Hand-edited list file with CRLF / trailing whitespace / `~/` prefixes** — read must normalize, never crash or double-record. (Pinned: list-file tests.)
4. **Malformed prefs (`repo_mode=banana`, junk lines)** — treated as absent (ask again); never a crash. (Pinned: prompts tests.)
5. **A repo reached only through a symlink** — `find -type d` does not match symlinked dirs; discovery deliberately does NOT follow symlinks (loop risk). Pin the not-found behaviour + keep explicit list lines working for it. (Pinned: discovery tests.)

---

### Task 1: Discovery engine (`_discover_repos` + `_repo_remote`)

**Files:**
- Modify: `backup.sh` (add functions after `_candidate_destinations`; introduce `CAPTURED_WHOLESALE` var; convert the `.claude-flow`/`.joyia`/`.ssh` `copy_rel` call sites to iterate it — same step, same log order)
- Create: `tests/test_discovery.sh`
- Modify: `tests/run-all.sh` (append the suite)

**Interfaces (produces):**
- `_discover_repos` — prints `$HOME`-relative repo roots, one per line, find order, nested-suppressed, prunes applied, depth ≤ 4.
- `_repo_remote <abs-dir>` — prints origin URL, else first remote URL, else empty (rc 0).
- `CAPTURED_WHOLESALE=".claude .claude-flow .joyia .ssh"` — single source for prune + copy steps.

**Test fixture helper** (in the test file): `mkrepo <path> [remote-url]` = `git init -q`, one `--allow-empty` commit with `-c user.email=t@t -c user.name=t`, optional `git remote add origin <url>`; worktrees via `git worktree add`.

- [ ] **Step 1: Failing tests** — `tests/test_discovery.sh` cases (all against fake HOMEs): simple repo found as rel path; linked-worktree `.git` FILE found; nested repo NOT listed; repo under EACH of: `Library`, `Library/CloudStorage/X`, `Dropbox`, `OneDrive`, `.Trash`, `.cache`, `.npm`, `.cargo`, `.rustup`, `go/pkg`, `claude-migration`, and each `CAPTURED_WHOLESALE` name — NOT listed (loop the prune list; one case per entry, so a dropped prune fails its own case); repo under `node_modules/`, `.venv/`, `venv/`, `__pycache__/` NOT listed; depth: `~/a/b/c/repo` found, `~/a/b/c/d/repo` not; spaces in path intact; symlinked repo dir NOT found (deliberate); `_repo_remote`: origin preferred, first-remote fallback, empty when none; output is `$HOME`-relative.
- [ ] **Step 2: Run → RED** (`/bin/bash tests/test_discovery.sh`: unknown-function / empty output failures).
- [ ] **Step 3: Implement** — one `find "$HOME" -maxdepth 4` pass: `-name .git -print` (matches dir AND file) under a prune expression; literal-path prunes from `CAPTURED_WHOLESALE` + the design list; name prunes for `node_modules .venv venv __pycache__`; then `dirname`, rel-path conversion, ancestor post-filter (drop roots whose path starts with an accepted root + `/`).
- [ ] **Step 4: Run → GREEN**; then `/bin/bash tests/run-all.sh` still green.
- [ ] **Step 5: Receipt** — suite counts + a MANUAL timing check: time the find on the real `$HOME` read-only (safe: `~/Library` pruned), record seconds in the handoff §7; must be well under ~10 s.

**Discriminant:** remove ONE prune (e.g. `Library/CloudStorage`) → its dedicated case must go RED; restore → GREEN. Shows the per-prune cases discriminate.
**🧪 Receipt:** suite counts, timing, mutation RED/GREEN lines, `git add tests/test_discovery.sh tests/run-all.sh backup.sh` commit.

### Task 2: List-file I/O + merge

**Files:** Modify `backup.sh` (add `_read_repo_list`, `_write_repo_list`, `_merge_repos`); Create `tests/test_repo_list.sh`; Modify `tests/run-all.sh`.

**Interfaces (produces):**
- `_read_repo_list <file>` — emits `state<TAB>path` lines: `record|exclude|copy|undecided`; skips blank/`#`; strips `~/` prefix, trailing `/`, CR, surrounding whitespace; unknown prefixes (`!`/`+`/`?`/bare only) treated as `record` with the literal line kept on rewrite.
- `_write_repo_list <file> <merged-content>` — atomic (mktemp in same dir + `mv`); prepends the generated header (explains bare/`!`/`+`/`?`/`#` + both reset ways) only when creating; preserves user `#` lines and relative order; appends new entries.
- `_merge_repos <discovered-rel-paths…>` — consumes read lines via stdin; sets: `DECIDED_*` arrays (record/exclude/copy/undecided), `NEW_REMOTE`/`NEW_NOREMOTE` arrays, `MISSING` array (listed, not on disk → warn "listed repo missing: X", line kept).

- [ ] **Step 1: Failing tests** — `tests/test_repo_list.sh`: parse each prefix; blank/`#` skipped; `~/x` → `x`; `x/` → `x`; CRLF line normalized; unknown-prefix line survives a read-write cycle; header written on create, not duplicated on rewrite; user comments + order preserved; new entries appended at end; atomic: temp file cleaned, target complete after write; missing entry warns + line kept; malformed list file (empty, header-only) handled.
- [ ] **Step 2: RED.** **Step 3: Implement.** **Step 4: GREEN** + run-all green.
- [ ] **Step 5: Receipt + commit** (paths: the three files).

**Discriminant:** mutation — drop the CR strip → CRLF case RED; drop atomic `mv` (write direct) → temp-file case RED.

### Task 3: Flow wiring (non-interactive paths)

**Files:** Modify `backup.sh` (replace the `255-266` block); Modify `tests/test_portability.sh` (**the one sanctioned change**: case 4 asserts the `repos:` summary instead of `no repos configured`); Create `tests/test_flow.sh`; Modify `tests/run-all.sh`.

**Interfaces (produces):** `REPOS[]` (record incl. auto-added bare lines), `COPIES[]` (`+` paths), `UNDecided_NAMES[]`, summary counters. Consumed by: git-record loop (Task 5 backup copy loop).

**Flow (replaces the block):** `MIGRATION_REPOS` set → old behaviour verbatim, return. Else: discover → merge → resolve mode: remembered pref | `auto` when non-terminal | **interim `auto` for terminal (replaced by the Task 4 prompt)** → new-remote repos: auto ⇒ append bare; review ⇒ pre-ticked list (kept for Task 4; interim auto) → new-noremote: terminal ⇒ (Task 4 per-repo menu; interim: write `?`) | non-terminal ⇒ write `?` + summary name → write list file when changed → summary line (+ names) → zero-found warning only when discovered=0 AND listed=0.
- [ ] Steps: failing tests → RED → implement → GREEN → receipt + commit.
- [ ] **Tests:** dry-run on fresh fake HOME prints the summary, writes nothing (existing case 4 shape, new assertion); `MIGRATION_REPOS` set ⇒ no discovery output, no list-file write even when repos exist; list file written when repos found (bare lines + header); `?` written for no-remote repo on non-terminal run; `!`-excluded repo not re-offered; second run asks nothing new (idempotent); missing listed repo warns + kept; zero-repos warning on truly empty HOME; `--dry-run` leaves NO list file and NO prefs file.

**Discriminant:** mutation — make the list-file write unconditional (even when unchanged) → the idempotence case RED; make `MIGRATION_REPOS` fall through to discovery → its case RED.

### Task 4: Prompts, menus, prefs, `--reset-choices`

**Files:** Modify `backup.sh` (`_ask_repo_mode`, `_startup_menu`, `_ask_no_remote`, `_review_new_repos`, `_reset_choices`, flag parse in the `while [ $# -gt 0 ]` loop, `usage()` line); Create `tests/test_prompts.sh`; Modify `tests/run-all.sh`.

**Interfaces (produces):** `_read_pref <key>` / `_write_pref <key> <value>` (atomic, `key=value` lines, unknown value = absent); mode prompt replaces Task 3's interim; startup menu opens (terminal, when prefs/list decisions exist) before discovery; per-repo menu replaces the interim `?` write for terminal no-remote repos; review menu gates auto-added bare lines in review mode; `--reset-choices`: parse (before any work), `usage()` documents it, non-terminal ⇒ exit 2 + message, `MIGRATION_REPOS` ⇒ exit 2 (no write), `--dry-run` ⇒ announce only; when run: delete `repo_mode`, turn `!`/`+`/`?` lines back into undecided for this run.

- [ ] **Step 1: Failing tests** — `tests/test_prompts.sh`, pty via `script -q /dev/null` + paced keys (1.5 s, per the harness's measured race): mode prompt review→review list shown→accept→prefs written after "remember? y"; remember=n → prefs absent; automatic mode → bare lines, no review menu; startup menu: Enter carries on (no re-ask), `2`/`c` re-asks mode, `3`/`r` re-decides an excluded repo, `q` aborts rc 1; per-repo menu: shows size, `1` copy ⇒ `+` line + tarball planned, `2` leave out ⇒ `!` line; review menu: toggle by number, `a`, `n`, Enter accept; remembered-choice-in-use line names both reset ways; **non-terminal proofs** (stdin `</dev/null`, wrapped in `perl -e 'alarm 20; exec @ARGV'`): full run with no list file and no prefs completes rc 0, writes `?` for no-remote, never prompts (no menu text, no hang); `--reset-choices` non-terminal ⇒ rc 2 + message, file untouched; `--reset-choices` + `MIGRATION_REPOS` ⇒ rc 2; `--reset-choices` + `--dry-run` (pty) ⇒ announces, prefs still present; `--reset-choices` (pty) ⇒ prefs `repo_mode` gone, `!` line re-asked; `--help` output contains `--reset-choices`; malformed pref value ⇒ treated as absent.
- [ ] **Step 2: RED** (each prompt case fails against interim defaults). **Step 3: Implement** (chrome → stderr; EOF ⇒ abort like `q`). **Step 4: GREEN** + run-all green.
- [ ] **Step 5: Receipt + commit.**

**Discriminant:** mutation — remove the `[ -t 0 ] && [ -t 1 ]` gate from ONE prompt path → the non-terminal proof case must RED (alarm fires or prompt text appears); restore.

### Task 5: Whole-tree copies (backup + restore)

**Files:** Modify `backup.sh` (mkdir `repo-copies` beside `repo-overlays`; copy loop consuming `COPIES[]`; `repos.tsv` row with empty URL for copies); Modify `restore.sh` (extraction branch in the repos loop); Modify `MANIFEST.md` heredoc (one line documenting `repo-copies/`); Create `tests/test_repo_copies.sh`; Modify `tests/run-all.sh`.

**Interfaces (consumes/produces):** backup: `COPIES[]` from Task 3 → `"$STAGE/repo-copies/<safe>.tar.gz"` where `safe="$(printf '%s' "$rel" | tr '/' '__')"`; file list = `git ls-files -z -c -o --exclude-standard` + `.git` tree, minus overlay greps + `.DS_Store`, `tar czf -C "$d" -T list`. restore: in the repos loop — empty URL + tarball exists + dest missing ⇒ `mkdir -p` dirname, `tar xzf` into dest, ok line; dest exists ⇒ skip + message; no tarball ⇒ existing warning unchanged.

- [ ] **Step 1: Failing tests** — `tests/test_repo_copies.sh`: backup side (real run, positional OUT, fake HOME): repo with committed + untracked-non-ignored + gitignored + `.git`; tarball exists; `tar -tzf` contains the tracked file, the untracked file, `.git/HEAD`; NOT the ignored file, NOT `.venv/…` even when tracked; repos.tsv row: empty URL field, sha non-empty; space-named repo ⇒ intact extraction paths. Restore side (brew stub on PATH, local-path remote or copy-only, fake HOME, archive from the backup step): `+` repo extracted to `$HOME/<rel>` WITH `.git`; second restore / pre-existing dest ⇒ skipped with message; old-archive shape (no `repo-copies/`, empty-URL row) ⇒ "no remote — skipping" warning, nothing extracted; restore of a remote repo unchanged.
- [ ] **Step 2: RED.** **Step 3: Implement.** **Step 4: GREEN** + run-all green.
- [ ] **Step 5: Receipt + commit.**

**Discriminant:** mutation — drop `+ .git` from the file list → the `.git/HEAD` assertion RED; make restore extract without checking dest-exists → the skip case RED.

### Task 6: Version 0.2.0, docs, full gate

**Files:** Modify `VERSION` (→ `0.2.0`), `CHANGELOG.md` (top entry `## [0.2.0] — 2026-11-09`, what + why), `README.md` (short repo-discovery section: automatic on first run, the prefixes, both reset ways, `--reset-choices`), Create `tests/test_e2e.sh`; Modify `tests/run-all.sh`.

- [ ] **Step 1: Failing test first** — `tests/test_e2e.sh`: the handoff §5.4 five-part fake HOME (repo w/ remote; repo w/o remote; linked worktree; repo under a pruned path; repo under `.claude`) — run 1 non-terminal: list file gets bare lines for remote+worktree, `?` for no-remote, nothing for pruned/.claude; run 2 pty seeding a `+` line + a `!` line: copy tarball built for `+`, excluded stays out, remembered-choice line printed; restore that archive (brew stub, fresh fake HOME): remote repo cloned+checked out, `+` repo extracted with `.git`, pruned/.claude absent from `$HOME` assertions where applicable. Also assert `backup.sh --help` contains `--reset-choices`.
- [ ] **Step 2: RED → implement version/doc bumps → GREEN.**
- [ ] **Step 3: Full gate receipt** — `/bin/bash tests/run-all.sh` (ALL SUITES PASSED, quote each suite's count line), `backup.sh --help` run showing the flag, e2e counts; `grep -rn '0\.1\.5'` shows only historical docs.
- [ ] **Step 4: Commit.**

**Discriminant:** mutation — revert VERSION to 0.1.5 → portability case 2 RED (proves the version pin is live).

---

## 🧨 Adversarial review

| Tempting shortcut | Plausible false success | Concrete harm | Rule → detecting check |
|---|---|---|---|
| Walk the real `$HOME` in a test | Suite green | Cloud downloads from `~/Library` / secrets in receipts | Authority-matrix ban; all fixtures fake HOME; discovery timing receipt is find-only, pruned |
| `git add -A` for speed | Commit "done" | User's unrelated dirty work lands in the commit | Stage by path (system instr. + global rule); `git diff --cached --stat` before each commit |
| Skip the pty pacing | Prompt tests pass locally | Race flakes for the next executor (measured 2026-11-08 in test_destinations) | Keep 1.5 s pacing + initial sleep, copy the harness helpers verbatim |
| Trust suite "ok" without mutation | Green = proven | An un-APPLIED mutation "reports caught" (playbook pitfall) | Verify the mutation landed (read the diff) before the RED run; restore to empty `git diff` |
| Assume old archives still restore | New restore "works" | Old archives (no `repo-copies/`) break at the empty-URL branch | Milestone (d) old-archive case is REQUIRED, not optional |
| Hardcode `$HOME`-absolute fixtures in test expectations | Tests pass | Portability test 1 greps `/Users/` and fails; machine-specific tests | Discovery output is $HOME-relative; expectations built from `$FAKE` variables |
| Push "when mostly green" | Branch visible | Consumers fetch a red branch | Push is GATED on the full-gate receipt (authority matrix) |
| Leave findings "rebutted in my head" | Next task starts | An open finding ships | Playbook standing rule: no next task with an open finding; rebuttals cite the proving line |

Risks not safely testable: real-`$HOME` cloud-download behaviour (never exercised — prunes are proven by planted repos instead); proxy/network flake during dispatches (documented fallback: self-review).

## 🏁 Final review and delivery

Implemented vs planned: state per task with its receipt. Receipts that ran: every suite count line + the full-gate receipt + QC milestone verdict tables in handoff §7. User work preserved: Phase 0 porcelain check; nothing outside `feat/repo-autodiscovery`. Secrets: fake HOMEs only; receipts quote no real paths beyond `$HOME`-relatives. Authorization boundary: **stop after pushing the branch** — no merge, tag, release, tap bump. Delivered artifact re-read: reread the handoff §7 + final commit log before reporting.
