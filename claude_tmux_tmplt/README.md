# claude_tmux_tmplt: a Claude Code team in tmux

> **Platform: macOS with Homebrew only.** Every script runs under Homebrew's bash 5 at `/opt/homebrew/bin/bash` (the newer ones start `#!/usr/bin/env bash` and are launched with it explicitly; those needing bash 4+ refuse an older bash), and several use macOS (BSD) `date -r`, `date -j` and `stat -f` flags. **On Linux, on a Mac without Homebrew's bash, or on an Intel Mac (whose Homebrew lives in `/usr/local`), the scripts fail** with "bad interpreter", or with `date`/`stat` errors. `install.sh` and `start_team.sh` check the platform and refuse to run anywhere else. Porting means changing the shebangs and the BSD `date`/`stat` calls; nothing has been tested on Linux.

This kit runs a small team of Claude Code sessions in one tmux session. A chief of staff (**cos**) turns your asks into launched, briefed worker sessions. An operations manager (**mgr**) keeps those workers healthy and honest, verifies what they claim, and gives them direction. Project teams work in **hive mode**: they share one append-only board per project instead of messaging each other status. Watchers, hooks and review sweeps catch mistakes and risky actions, and stay silent unless something is wrong. It is a template of the setup Frank Pari runs day to day, with the owner-specific parts replaced by placeholders.

## Requirements
- macOS, Apple Silicon Homebrew (`/opt/homebrew`): `brew install bash tmux jq coreutils` (coreutils provides `gtimeout`)
- Claude Code (`claude`) with a plan that covers several concurrent sessions plus headless review sweeps
- The models named in `tools/wtchr_sweeps.sh` and `start_team.sh`. Change them with the `SWEEP_*`, `COS_*` and `MGR_*` variables.
- For the memory database in `claude_kb/`: PostgreSQL with the pgvector and pg_trgm extensions, `pigz`, and ollama with an embedding model.

## Install
```bash
./install.sh            # dry run: prints the plan
./install.sh --go       # copies into $TEAM_ROOT (default ~/claude) and ~/.claude/hooks; never overwrites
```
Then:
1. Merge the printed `hooks` block into `~/.claude/settings.json`.
2. In `personas/cos.md` and `mgr.md`, replace `<OWNER>` and `<OWNER_ROLE_ONE_LINE>`. Review `house_rules.md`: it ships with two rules for the memory database, so set up `claude_kb/` (its README has the steps) or delete those two lines.
3. Test the hooks with `~/.claude/hooks/heredoc-guard-tests/run.sh`.
4. Run `./start_team.sh`, then `tmux attach -t hq`.
5. Optional: `install.sh` prints two more hook blocks. Block A adds a local date and time line to each prompt. Block B holds the two guards of the memory database; merge it when you set that up (`claude_kb/README.md`).
6. Optional, for public repos: list your private names (customers, hosts, internal projects; one per line) in `$TEAM_ROOT/.cos_tripwire/public_patterns.txt`, and add `tools/public_gate.sh` to each public clone's `pre-commit` and `pre-push` hooks (see the script's header).

Set `TEAM_ROOT` before installing to use a folder other than `~/claude`. The oversight plugin's `settings.json`, which every session launches with, passes `TEAM_ROOT` on to the sessions and their hooks.

## What's in the kit
```
install.sh, start_team.sh     install; start cos + mgr
house_rules.md                rules every session follows (edit to taste)
personas/                     cos.md, mgr.md, BRIEF_TEMPLATE.md; examples: worker, pm, coder, tester, qa,
                              reviewer (blind code reviewer), labWorker (spends money; + its settings example)
tools/                        the scripts (below) + oversight_plugin/ + cos_sweep_prompt.md + review_prompt.md
hooks/                        risk-log.sh, heredoc-guard.sh (+ tests), devnull-guard.sh
templates/                    empty cos_state.md, cos_sessions, cos_watch.tsv, cos_log.md, comms_lab.md,
                              drift_pending.txt, and .cos_tripwire/ with empty public-gate lists and an
                              empty fork_score.tsv
bash_tricks/                  bash example catalog by topic, plus our_bugs_bash_examples.md (traps we hit)
claude_kb/                    optional: the team's memory in one Postgres table (kb script, schema, two guards)
```

---

## 1. Layout

```
tmux session hq   (TMUX_SESSION; window numbers follow your tmux base-index)
├── win 0  cos        ┌ cos   (chief of staff)  ┐  the two coordinators
│                     └ mgr   (operations)      ┘  share window 0
├── win 1  <project>    <worker>
├── win 2  <project>  ┌ <proj>pm (PM, left) ┬ <proj>wkr  (coder)   ┐  optional team; shares
│                     │                     ├ <proj>tstr (tester)  │  <project>/BOARD.md
│                     └                     └ <proj>qa   (QA)      ┘
└── …      one window per project, task or workflow
   + short-lived panes: statrep (under cos), cosNote (under any pane)
```
- A window holds one project, and its panes are the Claude sessions working on it. Names are short and alphanumeric (`claude -n <name>`).
- Each Claude session registers in `~/.claude/sessions/<pid>.json` (name, sessionId, status, tmux pane). The scripts find sessions there, never by pane position.
- Review sweeps run headless (`claude -p`, no tools) outside tmux.

## 2. Roles

| | **cos** (win 0 left) | **mgr** (win 0 right) | **workers** |
|---|---|---|---|
| Job | Scopes asks into launched, briefed sessions: personas, briefs, launches, the workspace, template drift | Runs the sessions: verifies claims from the boards' pointers, gives direction, tripwire, board watch, sweeps, check-ins | Do the project work |
| Tells the owner | The answer to what they asked, launch reviews, risks in its own lane, corrections of what it said | Only risks (a RISK with no go, idle paid resources, cos down) and critical corrections (a wrong fact they acted on, uncorrected by its teller for 30 min) | Answers, decisions, risks, corrections in their own pane |
| Writes | `cos_state.md`, `cos_sessions`, `cos_log.md` | `cos_watch.tsv`, `.cos_tripwire/*`; runs the background jobs | Their project folder and board |
| Directs workers | No (launch briefs only) | **Yes** | the PM directs its team |

cos and mgr message each other only for a few things: from mgr, a session GONE, a finding about cos, a project that needs a launch, or two failed sweeps; from cos, a new launch or a job change that needs mgr to relaunch something. No acks and no FYIs. The owner's open decisions live in each project, kept by its PM; there is no central list.

**Worker patterns:** a single worker per window; a **team** of PM, coder, tester and QA (`personas/pm.example.md`, `coder.example.md`, `tester.example.md`, `qa.example.md`; drop the roles you don't need). The PM scopes, reviews and takes the outward actions (push and so on) on the owner's go in its own pane; the coder writes the main code and only commits locally; the tester writes the test tree in its own worktree; QA runs the suites and routes failures. Or a spending worker with a `personas/<name>.settings.json` that the owner attaches at launch: `personas/labWorker.example.md` is a cloud lab worker with a spend cap, a map of known traps and a trap log that cos keeps, and `personas/labWorker.settings.example.json` is its permission file to fill in. Or a **blind reviewer** (`personas/reviewer.example.md`) beside a team: it reviews each sha from its own clone with clean-room headless workers, reads none of the team's notes until its findings are filed, and then scores itself against the outside reviewers.

**Hive mode.** Each team shares `<project>/BOARD.md`, appended only by `tools/board.sh <project> <TYPE> <text…>`, which stamps the UTC time (TYPE: DONE BLOCKED Q RISK PUSHED DECISION NOTE HANDOFF). Work for another session is a `HANDOFF <to-session> …` line; each team session keeps one background shell on its board that exits, waking it, when a HANDOFF to it lands (the line is in `personas/BRIEF_TEMPLATE.md`). A teammate gets a message only for a blocker, a finished assignment (a hand-off that starts its next piece of work) or a question; everything else is one board line with a pointer (sha, rc file, path), never pasted output. Teams don't message cos or mgr: cos reads a board when it needs a team's state, and `tools/board_watch.sh` wakes mgr on RISK, PUSHED and BLOCKED lines. Why: every message wakes its receiver, which re-reads its whole context, so status traffic between sessions is the most expensive kind of output.

## 3. Session lifecycle

```
ask ──► persona + brief ──► launch ──────────────► register ─────► work ──► restart? ──► close
        personas/<n>.md      cos_sessrun.sh <n>      cos_sessions             cos_respawn.sh
        BRIEF_TEMPLATE.md    claude -n <n> … + oversight settings   cos_watch.tsv
```

| Step | How |
|---|---|
| Persona | `personas/<name>.md` (role, standards, how to work with the owner), passed with `--append-system-prompt-file`. The owner reviews it before launch. |
| Brief | Built from `personas/BRIEF_TEMPLATE.md`: the ask verbatim, what cos added, done means, binding rules, shared state, watching, parallelism. Sent as the launch prompt or by SendMessage, because long tmux pastes lose their start. |
| Launch | `tools/cos_sessrun.sh <name> claude -n <name> --model <m> --effort <e> --append-system-prompt-file personas/<name>.md --append-system-prompt "$(cat house_rules.md)" --settings tools/oversight_plugin/settings.json "<brief>"`, started from `$TEAM_ROOT`, since Claude Code's memory is keyed to the launch folder. The house rules ride in the system prompt because that survives `/compact`; a SessionStart hook's output is capped at 10 KB. The `cos_sessrun.sh` wrapper records the session's end: it removes the name from `cos_sessions` and adds one line to `cos_log.md`, also when the pane or window is closed. |
| Register | cos adds the session to `cos_sessions`; mgr adds each commitment, read from a board line or the brief, to `cos_watch.tsv` as `session<TAB>what it owes<TAB>due` (due as `YYYY-MM-DDTHH:MMZ` from `date -u`). |
| Restart | `tools/cos_respawn.sh <name> <model> <effort> [persona] [settings]` restarts an idle session (registry status `idle`, or `shell`: idle with a background job): `respawn-pane` with `--resume` and `--system-prompt-snapshot off`, keeping the conversation in a fresh process. The session's background jobs end with the old process, so it relaunches them. `tools/cos_selfrestart.sh` does the same for cos. |
| Close | cos verifies the headline claim, the window closes, and the wrapper removes the session from `cos_sessions` (cos does it by hand for a session that ran without the wrapper). |

## 4. Oversight: layers, quietest first

```
 every tool call ──► hooks (risk-log, heredoc-guard, devnull-guard)  ── deny or log
 every 6 steps   ──► oversight plugin fork (same model, no tools)    ── $TEAM_ROOT/.oversight/<id>.json
 every 30 s      ──► cos_tripwire.sh  (ASK / STALL / GONE)             ─┐
 every 30 s      ──► board_watch.sh   (RISK / PUSHED / BLOCKED lines)  ─┤
 every 15 min    ──► wtchr_sweeps.sh → cos_sweep.sh (headless review)  ─┼─► mgr ─► the session, its PM, or the owner
 hourly (:07)    ──► cos_checkin.sh   (owed work, prompts, idle)       ─┘
 every 60 s      ──► cos_mgrwatch.sh  (are mgr and its jobs alive?)   ──► cos
```

| Layer | Catches | Cost | Who acts |
|---|---|---|---|
| Hooks | `devnull-guard.sh` denies output to /dev/null; `heredoc-guard.sh` denies risky heredoc, `rm -r $var` and launchctl patterns; `risk-log.sh` logs outward or destructive calls to `.cos_tripwire/risk.log` | 0 tokens | the session; the sweeps read risk.log |
| Oversight plugin | Every 6 main steps it forks the session's own model, with no tools, to look for RISK, MISTAKE, RULE or INEFF | one forked turn per check, mostly cache reads | mgr reads `.oversight/*.json` and scores each concern in `.cos_tripwire/fork_score.tsv` |
| Tripwire | A prompt unanswered 5+ min outside the pane being viewed; a busy pane unchanged 15+ min; a vanished session | 0 tokens | mgr (a prompt waits in the worker's pane; it never goes to the owner's chat) |
| Board watch | A RISK, PUSHED or BLOCKED line on any board, or a board that shrank | 0 tokens | mgr checks the go (RISK), `git ls-remote` and the quoted go (PUSHED), the pane (BLOCKED) |
| Review sweeps | Every session's transcript delta and its sub-agents, plus risk.log, judged against each session's persona and launch prompt and the house rules (RISK, MISTAKE, RULE, INEFF, FORMAT, public exposure). The regular model runs at :00/:30/:45, the deep model at :15; a batch the deep model's safeguards refuse is rerun once on the retry model. cos is reviewed too. A batch result must start with FINDINGS or CLEAN: any other start is a failed batch, and the next sweep reads that range again. The last 8 runs' raw results stay in `.cos_tripwire/sweep/keep/` | headless `claude -p` only when there's new activity | A RISK wakes mgr at once; other findings wait for :20. mgr routes only a RISK without a go and real mistakes, at most one message per session per hour; RULE, INEFF and FORMAT are logged, and FORMAT-only output never wakes mgr |
| Check-in | Sessions owing work while idle, past due, or waiting on a prompt | one wake per hour | mgr reads the board, then nudges or redirects |
| mgr watch | mgr gone, one of its four jobs not running exactly once, a stale snapshot (3 checks in a row) | 0 tokens | cos |
| Public gate (optional) | Names from your list, cloud OCIDs, private keys or new private IPs in a commit to a public repo (`tools/public_gate.sh` in pre-commit/pre-push hooks), and after the fact in new public commits (`tools/public_watch.sh`, run by mgr) | 0 tokens | the committer; mgr on a watch hit, or when the watch can't reach a repo three times in a row (PUBLIC WATCH BLIND) |

Watchers stay silent unless something is wrong. Don't use looping agent watchers: they wake the coordinator every minute and burn tokens.

## 5. Communication

| Channel | Used for |
|---|---|
| Chat in a pane | **Action items only:** decisions, things the owner must do, risks, corrections, answers. One open decision per message, with a recommendation. |
| SendMessage | Launch briefs, routed findings, and between teammates only a blocker, a finished assignment or a question. Never the owner's go. |
| `<project>/BOARD.md` | A team's shared state: one stamped line per entry, appended only by `tools/board.sh`, with a pointer to the evidence |
| `cos_state.md` | The live picture: windows, sessions, standing rules, and a pointer to each team's board |
| Project notes | Decisions with the owner's words and UTC stamp, and the PM's requirements per piece of work. Nothing the transcript already holds. |
| `cos_log.md`, `.cos_tripwire/mgr_log.md` | Exceptions that would otherwise be play-by-play in chat |
| `.cos_tripwire/review.log`, `risk.log` | Every sweep verdict; every outward call |
| `tools/cos_statrep.sh <win>` | A 12-line pane under cos showing `cos_statrep`, for updates that need no reply |
| `tools/cos_note.sh <pane>` | A short note pane just under the pane it's about |

Every finding starts with **VERIFIED** (the command or line that shows it) or **HYPOTHESIS**. Every time written to a log, note or board is UTC from `date -u`.

## 6. Authority and safety
- **The owner's go happens in the pane that acts.** Auto mode blocks relayed approvals, so cos tells the owner what to type and where, and never routes around a denial.
- **Outward actions** (chat, tickets, docs, pushes, cloud spend) need the owner's word or a standing rule recorded in `cos_state.md` with its scope and expiry. Local commits are fine.
- Nobody answers a permission prompt for the owner. Deletes only touch paths the run itself created and logged.
- Everything else is in `house_rules.md`.

## 7. Reboot recovery
```
mgr: cos_snapshot.sh (every 60 s) ──► restore/manifest.jsonl (+20 versions in restore/history/)
                                       one JSON row per pane: window, layout, name, sessionId, cwd,
                                       model, effort, persona, settings (read from the live argv)
after a reboot, by hand:
   tools/cos_restore.sh          dry run: prints the plan
   tools/cos_restore.sh --go     rebuilds windows, panes and layouts; resumes each Claude with its last
                                 flags plus a post-reboot prompt (cos / mgr / worker variants)
```
Restore exits 0 with "already running" if the tmux session exists (so `cos_restore.sh --go && tmux attach -t hq` works as one alias), and refuses if any manifest session is still running. It takes window and pane numbers from tmux, so `base-index` 0 or 1 both work, and it reads a relative persona or settings path from the session's launch folder. Background jobs, crons and ssh loops don't survive a reboot; each role's post-reboot prompt says what to relaunch.

## 8. Scripts (`tools/`)

| Script | Purpose | Run by | How |
|---|---|---|---|
| `cos_tripwire.sh` | ASK, STALL and GONE watcher | mgr | background; exits to wake mgr; relaunched after each wake |
| `wtchr_sweeps.sh` | quarter-hour sweep scheduler; holds findings, wakes on a RISK or a failure | mgr | background |
| `cos_sweep.sh` + `cos_sweep_prompt.md` | one headless review sweep → `review.log` | wtchr_sweeps.sh | `cos_sweep.sh MODEL EFFORT`; exit 0 findings / 1 clean / 2 nothing new / 3 failed |
| `cos_snapshot.sh` | reboot manifest | mgr | background, every 60 s |
| `cos_restore.sh` | rebuild the tmux session after a reboot | owner | by hand, dry run first, then `--go` |
| `cos_checkin.sh` | per-session status plus FLAG lines | mgr | hourly cron at :07 |
| `board.sh` | append one stamped line to a team's `BOARD.md` | every team session | `board.sh [-s <session>] <project> <TYPE> <text…>`; exit 2 and nothing written on bad input |
| `board_watch.sh` | wakes mgr on a RISK, PUSHED or BLOCKED board line, or a shrunk board | mgr | background, launched as `/opt/homebrew/bin/bash …/board_watch.sh` |
| `public_gate.sh` | blocks a commit or push to a public repo that carries listed names, OCIDs, keys or new private IPs | git hooks | `pre-commit` / `pre-push` in each public clone |
| `public_watch.sh` | scans new commits in your public repos for the same; also wakes mgr when it can't reach a repo (`FAILS`, default 3 polls) | mgr | background, `PUBLIC_REPOS="you/repo …"` |
| `review_prompt.md` | a general code-review prompt to fill in and send | anyone | copy, fill the placeholders |
| `cos_mgrwatch.sh` | checks mgr and its 4 jobs | cos | background |
| `cos_tmpltdrift.sh` | optional: wakes cos when the live team's core files drift from the last reviewed baseline, for owners who keep a shared copy of the kit | cos | background; `--accept` re-baselines; changes the kit still lacks wait in `drift_pending.txt` |
| `cos_sessrun.sh` | launch wrapper: records a session's end in `cos_sessions` and `cos_log.md` | every new session's launch line | `cos_sessrun.sh <name> claude -n <name> …` |
| `owner_said.sh` | prints the UTC stamp and text of the owner's last typed message in a session, for quoting a go | anyone | `owner_said.sh <session> [regex] [count]` |
| `cos_respawn.sh` | restart an idle session in its pane | cos | on demand |
| `cos_selfrestart.sh` | cos restarts itself once it's idle and the owner isn't viewing its window | cos | `nohup … &` |
| `cos_statrep.sh` / `cos_note.sh` | statrep pane / note pane | cos | body on stdin |
| `agent_watch.sh` | failure-aware watcher for long jobs or sub-agents (stale, timeout, done) | workers | background |
| `oversight_plugin/` | per-session fork reviewer | every session | `--settings tools/oversight_plugin/settings.json` |

Outside `tools/`: `claude_kb/kb` is the optional memory database (search, ask, show, add, edit, retire, backup, prune), with its own `README.md` and two PreToolUse guards. No script uses it, but `house_rules.md` ships with its two rules: set it up, or delete them.

## 9. What was tested (macOS, bash 5; each block gives its date)
**2026-10-25, tested on the kit copy against a live team:**
- Every script passes `bash -n`; the plugin passes `node --check`.
- heredoc-guard suite: 39 passed, 0 failed. That is 38 fixtures plus a timing test; one private fixture was dropped from the original 39. The suite prints one `jq: parse error` on stderr, which is expected: `err-malformed-input.json` feeds bad JSON on purpose and passes only when the guard reports it could not check.
- `install.sh` dry run, `--go` into a fresh root, and a rerun into the same root (0 new, 97 kept; an edited persona stays).
- `start_team.sh` on an isolated tmux server with a stand-in `claude`: cos left, mgr right, the right flags. It refuses while placeholders remain and when the session exists.
- `cos_snapshot.sh` (ONCE) and the `cos_restore.sh` dry run against the live session: every row's flags are right, and both refusals fire.
- `cos_mgrwatch.sh` (ONCE): healthy against a live team, and it reports all 3 jobs missing against an empty root.
- `cos_checkin.sh` against live state.
- `cos_selfrestart.sh` (DRY).
- `cos_tmpltdrift.sh` (2026-10-26, ONCE, on a scratch team root): no baseline exits 2, `--accept` then clean exits 0, a new persona file exits 1 and is listed, a pending line exits 3 and is listed, a comment-only pending file is clean.
- `risk-log.sh` logs a `git push` but not an `ls`; `devnull-guard.sh` denies a redirect and allows a plain command.

**Added 2026-11-03 (hive mode and the rules since 10-26), tested on the kit copy against scratch roots:**
- All 22 scripts pass `bash -n` under bash 5; the plugin passes `node --check`; heredoc-guard suite 39 passed, 0 failed.
- `board.sh`, under bash 3.2 and 5: an append lands with a UTC stamp; a bad TYPE, a missing project, a bad session name, a two-line text, a 201-character text, `../x` as project, and no session name each exit 2 (16/16). With only `TEAM_ROOT` set, it writes under `TEAM_ROOT`.
- `board_watch.sh`: refuses bash 3.2 (exit 2); `ONCE=1` lists the boards and saves offsets; a NOTE that says "blocked" doesn't wake it; a BLOCKED line does.
- `public_gate.sh` in a scratch git repo: clean text passes; a listed name, an OCID and a new private IP each block; an IP in the baseline passes; a missing list exits 1; `pre-push` blocks a listed name in a new commit. `public_watch.sh` refuses to start without `PUBLIC_REPOS`.
- `cos_sweep.sh` with a stand-in `claude` that refuses the deep model: the batch is rerun on the retry model, review.log records the rerun, and the input is kept in `sweep/failed/`.
- `cos_checkin.sh`'s due parsing: `YYYY-MM-DDTHH:MMZ` and the older local format both parse; past and future dues are told apart.
- `cos_mgrwatch.sh` (ONCE) on an empty root reports all four jobs missing.
- `install.sh --go` into a fresh root: 108 new files, including the empty public-gate lists; a rerun keeps all 108.

**Added 2026-11-20 (fixes from a code review of the kit, and the changes on the live team since 11-03), tested on the kit copy. Every test used a scratch home and team root, a stand-in `claude`, and separate tmux servers:**
- All 25 scripts pass `bash -n` under bash 5; the plugin passes `node --check`; heredoc-guard suite 39 passed, 0 failed.
- `cos_sweep.sh` (28 checks): a CLI warning on stderr no longer hides FINDINGS; a result that starts with neither FINDINGS nor CLEAN fails the batch, the offsets stay, and the next sweep reads the range again; a failed result adds no "already reported" line; an earlier `[session] TYPE:` finding reaches the next sweep's "Already reported" list; a missing prompt file fails the sweep; `sweep/keep` holds the last `KEEP` runs.
- tmux scripts (40 checks), with `base-index` and `pane-base-index` at 0 and at 1, and with zsh as tmux's `default-shell`: `start_team.sh`; `cos_snapshot.sh` (a wrong session name writes no `last_snapshot`); `cos_restore.sh` run from another folder with relative persona and settings paths (dry run exits 0, `--go` keeps window numbers and pane order, "already running" exits 0); `cos_note.sh` and `cos_statrep.sh` (the pane stays open until Enter); `cos_respawn.sh` (status `shell` accepted, `busy` refused); `cos_mgrwatch.sh` counts jobs launched as `tools/<script>`, `./tools/<script>` and by full path.
- Other scripts (36 checks): `public_watch.sh` against local bare repos (an unreachable remote exits with PUBLIC WATCH BLIND after `FAILS` polls; a remote that comes back with a listed name gives PUBLIC HIT; a healthy, unchanged remote stays silent); `cos_sessrun.sh` (clean end, HUP, a restart in the pane, bash 3.2); `owner_said.sh`; `board.sh` HANDOFF and the watcher line; `public_gate.sh` log stamps.

**Added 2026-11-20, second update (the optional memory database, two example personas, small rules), tested on the kit copy:**
- All 28 scripts pass `bash -n` under bash 5; the plugin passes `node --check`; heredoc-guard suite 39 passed, 0 failed.
- `claude_kb/kb` (33 checks) on a separate PostgreSQL 18 server with its own data folder, socket and port, a scratch home and `KB_DB` set: `init` twice; `load` with no files, with three files, and again (no new rows); `list`, `search` by keyword and by fragment, `show`, `history`; `add` (and its refusals), `edit`, `retire` (no row is deleted); `embed` and `ask` with ollama (the right memory ranks first), and `ask` without it (exit 1 with the reason); `backup`, a restore of the dump into a new database, and `prune`.
- `kb-guard.sh` and `memory-guard.sh` (30 checks), fed PreToolUse JSON with a scratch home: each deny and allow case, `KB_DB`, the `~` spelling of the folder, malformed input (allowed; `jq` prints one parse error on stderr), the deny text names the kit's `kb` path, and each deny is logged.
- `install.sh`: the dry run; `--go` into a fresh root (119 new files, `claude_kb/` and the new examples among them); a rerun keeps all 119. The three printed hook blocks parse with `jq`.

**Not tested from the kit:**
- `claude_kb`: an hourly backup job (cron or launchd), another embedding model, and the two guards as live hooks in a session started from the kit.
- `personas/labWorker.example.md`, `labWorker.settings.example.json` and `reviewer.example.md`: no session was launched from them. They are generic forms of personas in live use. The headless command in the reviewer example was checked against `claude --help` only; canary one worker first, as the persona says.
- `wtchr_sweeps.sh` (its loop runs on the clock; only two time stamps changed) and `cos_sweep.sh` with a real model (the originals run live).
- `cos_tripwire.sh`, `agent_watch.sh` (only path changes from the live originals).
- The oversight plugin with a non-default `TEAM_ROOT` (the default path is the one in live use).
- A full `start_team.sh` with real Claude sessions.
- Linux (unsupported).

## 10. Adapting it
- **Owner:** the placeholders in `personas/cos.md` and `mgr.md`; your own rules in `house_rules.md`.
- **Models:** `SWEEP_MODEL`/`SWEEP_EFFORT`, `SWEEP_DEEP_MODEL`/`SWEEP_DEEP_EFFORT` (sweeps), `SWEEP_RETRY_MODEL`/`SWEEP_RETRY_EFFORT` (rerun of a refused batch), `COS_*`/`MGR_*` (start_team.sh).
- **Boards:** `BOARD_ROOT` (default `$TEAM_ROOT`), `BOARD_MAX` (line length, default 200). **Public repos:** `PUBLIC_REPOS` for `public_watch.sh`; the lists in `.cos_tripwire/`.
- **Outward CLIs:** add your own tools' write verbs to the patterns in `hooks/risk-log.sh`.
- **Root and session:** `TEAM_ROOT` (default `~/claude`), `TMUX_SESSION` (default `hq`).
- **Linux:** not supported as shipped; see the Platform note at the top.

Author: Frank Pari.
