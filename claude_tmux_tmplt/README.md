# claude_tmux_tmplt: a Claude Code team in tmux

> **Platform: macOS with Homebrew only.** Every script runs under Homebrew's bash 5 at `/opt/homebrew/bin/bash` (the newer ones start `#!/usr/bin/env bash` and are launched with it explicitly; those needing bash 4+ refuse an older bash), and several use macOS (BSD) `date -r`, `date -j` and `stat -f` flags. **On Linux, on a Mac without Homebrew's bash, or on an Intel Mac (whose Homebrew lives in `/usr/local`), the scripts fail** with "bad interpreter", or with `date`/`stat` errors. `install.sh` and `start_team.sh` check the platform and refuse to run anywhere else. Porting means changing the shebangs and the BSD `date`/`stat` calls; nothing has been tested on Linux.

This kit runs a small team of Claude Code sessions in one tmux session. A chief of staff (**cos**) turns your asks into launched, briefed worker sessions. An operations manager (**mgr**) keeps those workers healthy and honest, verifies what they claim, and gives them direction. Project teams work in **hive mode**: they share one append-only board per project instead of messaging each other status. Watchers, hooks and review sweeps catch mistakes and risky actions, and stay silent unless something is wrong. It is a template of the setup Frank Pari runs day to day, with the owner-specific parts replaced by placeholders.

## Requirements
- macOS, Apple Silicon Homebrew (`/opt/homebrew`): `brew install bash tmux jq coreutils` (coreutils provides `gtimeout`)
- Claude Code (`claude`) with a plan that covers several concurrent sessions plus headless review sweeps
- The models named in `tools/wtchr_sweeps.sh` and `start_team.sh`. Change them with the `SWEEP_*`, `COS_*` and `MGR_*` variables.

## Install
```bash
./install.sh            # dry run: prints the plan
./install.sh --go       # copies into $TEAM_ROOT (default ~/claude) and ~/.claude/hooks; never overwrites
```
Then:
1. Merge the printed `hooks` block into `~/.claude/settings.json`.
2. In `personas/cos.md` and `mgr.md`, replace `<OWNER>` and `<OWNER_ROLE_ONE_LINE>`. Review `house_rules.md`.
3. Test the hooks with `~/.claude/hooks/heredoc-guard-tests/run.sh`.
4. Run `./start_team.sh`, then `tmux attach -t 0`.
5. Optional, for public repos: list your private names (customers, hosts, internal projects; one per line) in `$TEAM_ROOT/.cos_tripwire/public_patterns.txt`, and add `tools/public_gate.sh` to each public clone's `pre-commit` and `pre-push` hooks (see the script's header).

Set `TEAM_ROOT` before installing to use a folder other than `~/claude`. The oversight plugin's `settings.json`, which every session launches with, passes `TEAM_ROOT` on to the sessions and their hooks.

## What's in the kit
```
install.sh, start_team.sh     install; start cos + mgr
house_rules.md                rules every session follows (edit to taste)
personas/                     cos.md, mgr.md, BRIEF_TEMPLATE.md, worker / pm / coder / tester / qa examples
tools/                        the scripts (below) + oversight_plugin/ + cos_sweep_prompt.md + review_prompt.md
hooks/                        risk-log.sh, heredoc-guard.sh (+ tests), devnull-guard.sh
templates/                    empty cos_state.md, cos_sessions, cos_watch.tsv, cos_log.md, comms_lab.md,
                              drift_pending.txt, and .cos_tripwire/ with empty public-gate lists
bash_tricks/                  bash example catalog by topic, plus our_bugs_bash_examples.md (traps we hit)
```

---

## 1. Layout

```
tmux session 0
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

**Worker patterns:** a single worker per window; a **team** of PM, coder, tester and QA (`personas/pm.example.md`, `coder.example.md`, `tester.example.md`, `qa.example.md`; drop the roles you don't need). The PM scopes, reviews and takes the outward actions (push and so on) on the owner's go in its own pane; the coder writes the main code and only commits locally; the tester writes the test tree in its own worktree; QA runs the suites and routes failures. Or a spending worker with a `personas/<name>.settings.json` that the owner attaches at launch.

**Hive mode.** Each team shares `<project>/BOARD.md`, appended only by `tools/board.sh <project> <TYPE> <text…>`, which stamps the UTC time (TYPE: DONE BLOCKED Q RISK PUSHED DECISION NOTE). A teammate gets a message only for a blocker, a finished assignment (a hand-off that starts its next piece of work) or a question; everything else is one board line with a pointer (sha, rc file, path), never pasted output. Teams don't message cos or mgr: cos reads a board when it needs a team's state, and `tools/board_watch.sh` wakes mgr on RISK, PUSHED and BLOCKED lines. Why: every message wakes its receiver, which re-reads its whole context, so status traffic between sessions is the most expensive kind of output.

## 3. Session lifecycle

```
ask ──► persona + brief ──► launch ──────────────► register ─────► work ──► restart? ──► close
        personas/<n>.md      claude -n <n> …        cos_sessions             cos_respawn.sh
        BRIEF_TEMPLATE.md    + oversight settings   cos_watch.tsv
```

| Step | How |
|---|---|
| Persona | `personas/<name>.md` (role, standards, how to work with the owner), passed with `--append-system-prompt-file`. The owner reviews it before launch. |
| Brief | Built from `personas/BRIEF_TEMPLATE.md`: the ask verbatim, what cos added, done means, binding rules, shared state, watching, parallelism. Sent as the launch prompt or by SendMessage, because long tmux pastes lose their start. |
| Launch | `claude -n <name> --model <m> --effort <e> --append-system-prompt-file personas/<name>.md --settings tools/oversight_plugin/settings.json "<brief>"`, started from `$TEAM_ROOT`, since Claude Code's memory is keyed to the launch folder. |
| Register | cos adds the session to `cos_sessions`; mgr adds each commitment, read from a board line or the brief, to `cos_watch.tsv` as `session<TAB>what it owes<TAB>due` (due as `YYYY-MM-DDTHH:MMZ` from `date -u`). |
| Restart | `tools/cos_respawn.sh <name> <model> <effort> [persona] [settings]` restarts an idle session: `respawn-pane` with `--resume` and `--system-prompt-snapshot off`, keeping the conversation in a fresh process. `tools/cos_selfrestart.sh` does the same for cos. |
| Close | cos verifies the headline claim, the window closes, and cos removes the session from `cos_sessions`. |

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
| Oversight plugin | Every 6 main steps it forks the session's own model, with no tools, to look for RISK, MISTAKE, RULE or INEFF | one forked turn per check, mostly cache reads | mgr reads `.oversight/*.json` |
| Tripwire | A prompt unanswered 5+ min outside the pane being viewed; a busy pane unchanged 15+ min; a vanished session | 0 tokens | mgr (a prompt waits in the worker's pane; it never goes to the owner's chat) |
| Board watch | A RISK, PUSHED or BLOCKED line on any board, or a board that shrank | 0 tokens | mgr checks the go (RISK), `git ls-remote` and the quoted go (PUSHED), the pane (BLOCKED) |
| Review sweeps | Every session's transcript delta and its sub-agents, plus risk.log, judged against each session's persona and launch prompt and the house rules (RISK, MISTAKE, RULE, INEFF, FORMAT, public exposure). The regular model runs at :00/:30/:45, the deep model at :15; a batch the deep model's safeguards refuse is rerun once on the retry model. cos is reviewed too | headless `claude -p` only when there's new activity | A RISK wakes mgr at once; other findings wait for :20. mgr routes only a RISK without a go and real mistakes, at most one message per session per hour; RULE, INEFF and FORMAT are logged, and FORMAT-only output never wakes mgr |
| Check-in | Sessions owing work while idle, past due, or waiting on a prompt | one wake per hour | mgr reads the board, then nudges or redirects |
| mgr watch | mgr gone, one of its four jobs not running exactly once, a stale snapshot (3 checks in a row) | 0 tokens | cos |
| Public gate (optional) | Names from your list, cloud OCIDs, private keys or new private IPs in a commit to a public repo (`tools/public_gate.sh` in pre-commit/pre-push hooks), and after the fact in new public commits (`tools/public_watch.sh`, run by mgr) | 0 tokens | the committer; mgr on a watch hit |

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
Restore refuses if the tmux session exists or any manifest session is still running. Background jobs, crons and ssh loops don't survive a reboot; each role's post-reboot prompt says what to relaunch.

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
| `public_watch.sh` | scans new commits in your public repos for the same | mgr | background, `PUBLIC_REPOS="you/repo …"` |
| `review_prompt.md` | a general code-review prompt to fill in and send | anyone | copy, fill the placeholders |
| `cos_mgrwatch.sh` | checks mgr and its 4 jobs | cos | background |
| `cos_tmpltdrift.sh` | optional: wakes cos when the live team's core files drift from the last reviewed baseline, for owners who keep a shared copy of the kit | cos | background; `--accept` re-baselines; changes the kit still lacks wait in `drift_pending.txt` |
| `cos_respawn.sh` | restart an idle session in its pane | cos | on demand |
| `cos_selfrestart.sh` | cos restarts itself once it's idle and the owner isn't viewing its window | cos | `nohup … &` |
| `cos_statrep.sh` / `cos_note.sh` | statrep pane / note pane | cos | body on stdin |
| `agent_watch.sh` | failure-aware watcher for long jobs or sub-agents (stale, timeout, done) | workers | background |
| `oversight_plugin/` | per-session fork reviewer | every session | `--settings tools/oversight_plugin/settings.json` |

## 9. What was tested (2026-10-25, macOS, bash 5, against a live team)
**Tested on the kit copy:**
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

**Not tested from the kit:**
- `cos_sweep.sh` and `wtchr_sweeps.sh` (they spend model tokens; the originals run live).
- `cos_tripwire.sh`, `cos_respawn.sh`, `cos_statrep.sh`, `cos_note.sh`, `agent_watch.sh` (only path changes from the live originals).
- The oversight plugin with a non-default `TEAM_ROOT` (the default path is the one in live use).
- A full `start_team.sh` with real Claude sessions.
- Linux (unsupported).

## 10. Adapting it
- **Owner:** the placeholders in `personas/cos.md` and `mgr.md`; your own rules in `house_rules.md`.
- **Models:** `SWEEP_MODEL`/`SWEEP_EFFORT`, `SWEEP_DEEP_MODEL`/`SWEEP_DEEP_EFFORT` (sweeps), `SWEEP_RETRY_MODEL`/`SWEEP_RETRY_EFFORT` (rerun of a refused batch), `COS_*`/`MGR_*` (start_team.sh).
- **Boards:** `BOARD_ROOT` (default `$TEAM_ROOT`), `BOARD_MAX` (line length, default 200). **Public repos:** `PUBLIC_REPOS` for `public_watch.sh`; the lists in `.cos_tripwire/`.
- **Outward CLIs:** add your own tools' write verbs to the patterns in `hooks/risk-log.sh`.
- **Root and session:** `TEAM_ROOT` (default `~/claude`), `TMUX_SESSION` (default `0`).
- **Linux:** not supported as shipped; see the Platform note at the top.

Author: Frank Pari.
