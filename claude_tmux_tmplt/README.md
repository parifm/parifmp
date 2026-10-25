# claude_tmux_tmplt: a Claude Code team in tmux

> **Platform: macOS with Homebrew only.** Every script runs under Homebrew's bash 5 at `/opt/homebrew/bin/bash`, and several use macOS (BSD) `date -r`, `date -j` and `stat -f` flags. **On Linux, on a Mac without Homebrew's bash, or on an Intel Mac (whose Homebrew lives in `/usr/local`), the scripts fail** with "bad interpreter", or with `date`/`stat` errors. `install.sh` and `start_team.sh` check the platform and refuse to run anywhere else. Porting means changing the shebangs and the BSD `date`/`stat` calls; nothing has been tested on Linux.

This kit runs a small team of Claude Code sessions in one tmux session. A chief of staff (**cos**) turns your asks into scoped work for named worker sessions. An operations manager (**mgr**) keeps those workers healthy and honest in the background. Watchers, hooks and review sweeps catch mistakes and risky actions, and stay silent unless something is wrong. It is a template of the setup Frank Pari runs day to day, with the owner-specific parts replaced by placeholders.

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

Set `TEAM_ROOT` before installing to use a folder other than `~/claude`. The oversight plugin's `settings.json`, which every session launches with, passes `TEAM_ROOT` on to the sessions and their hooks.

## What's in the kit
```
install.sh, start_team.sh     install; start cos + mgr
house_rules.md                rules every session follows (edit to taste)
personas/                     cos.md, mgr.md, BRIEF_TEMPLATE.md, worker / pm / coder examples
tools/                        the scripts (below) + oversight_plugin/ + cos_sweep_prompt.md
hooks/                        risk-log.sh, heredoc-guard.sh (+ tests), devnull-guard.sh
templates/                    empty cos_state.md, cos_sessions, cos_watch.tsv, cos_log.md, comms_lab.md
bash_tricks/                  bash example catalog by topic, plus our_bugs_bash_examples.md (traps we hit)
```

---

## 1. Layout

```
tmux session 0
├── win 0  cos        ┌ cos   (chief of staff)  ┐  the two coordinators
│                     └ mgr   (operations)      ┘  share window 0
├── win 1  <project>    <worker>
├── win 2  <project>  ┌ <proj>pm  (PM, left)    ┐  optional PM + coder pair
│                     └ <proj>wkr (coder, right)┘
└── …      one window per project, task or workflow
   + short-lived panes: statrep (under cos), cosNote (under any pane)
```
- A window holds one project, and its panes are the Claude sessions working on it. Names are short and alphanumeric (`claude -n <name>`).
- Each Claude session registers in `~/.claude/sessions/<pid>.json` (name, sessionId, status, tmux pane). The scripts find sessions there, never by pane position.
- Review sweeps run headless (`claude -p`, no tools) outside tmux.

## 2. Roles

| | **cos** (win 0 left) | **mgr** (win 0 right) | **workers** |
|---|---|---|---|
| Job | Turns asks into scoped work: briefs, personas, launches, new direction, recommendations | Background health and honesty: tripwire, sweeps, check-ins, routing findings | Do the project work |
| Tells the owner | Asks, launches, results, every open call or decision (one list), worker questions, gos | Only: a worker blocked on a prompt, a RISK with no go, a wrong fact uncorrected for 30 min | Their own action items |
| Writes | `cos_state.md`, `cos_sessions`, `cos_watch.tsv`, `cos_log.md` | `.cos_tripwire/*`; runs the background jobs | Their project folder |
| Directs workers | **Yes** (only cos) | No: nudges only on what's owed | n/a |

cos and mgr message each other only for a few things: from mgr, a session GONE, a finding about cos, a worker that needs direction, idle paid resources, or two failed sweeps; from cos, a job change that needs mgr to relaunch something. No acks and no FYIs.

**Worker patterns:** a single worker per window; a **PM + coder pair**, where the PM scopes, reviews and takes the outward actions (push and so on) on the owner's go in its own pane, and the coder is the repo's only writer and only commits locally (`personas/pm.example.md`, `coder.example.md`); or a spending worker with a `personas/<name>.settings.json` that the owner attaches at launch.

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
| Register | cos adds the session to `cos_sessions`, and adds each commitment to `cos_watch.tsv` as `session<TAB>what it owes<TAB>due`. |
| Restart | `tools/cos_respawn.sh <name> <model> <effort> [persona] [settings]` restarts an idle session: `respawn-pane` with `--resume` and `--system-prompt-snapshot off`, keeping the conversation in a fresh process. `tools/cos_selfrestart.sh` does the same for cos. |
| Close | cos verifies the headline claim, the window closes, and cos removes the session from `cos_sessions`. |

## 4. Oversight: layers, quietest first

```
 every tool call ──► hooks (risk-log, heredoc-guard, devnull-guard)  ── deny or log
 every 6 steps   ──► oversight plugin fork (same model, no tools)    ── $TEAM_ROOT/.oversight/<id>.json
 every 30 s      ──► cos_tripwire.sh  (ASK / STALL / GONE)             ─┐
 every 15 min    ──► wtchr_sweeps.sh → cos_sweep.sh (headless review)  ─┼─► mgr ─► the session, or the owner, or cos
 hourly (:07)    ──► cos_checkin.sh   (owed work, prompts, idle)       ─┘
 every 60 s      ──► cos_mgrwatch.sh  (are mgr and its jobs alive?)   ──► cos
```

| Layer | Catches | Cost | Who acts |
|---|---|---|---|
| Hooks | `devnull-guard.sh` denies output to /dev/null; `heredoc-guard.sh` denies risky heredoc, `rm -r $var` and launchctl patterns; `risk-log.sh` logs outward or destructive calls to `.cos_tripwire/risk.log` | 0 tokens | the session; the sweeps read risk.log |
| Oversight plugin | Every 6 main steps it forks the session's own model, with no tools, to look for RISK, MISTAKE, RULE or INEFF | one forked turn per check, mostly cache reads | mgr reads `.oversight/*.json` |
| Tripwire | A prompt unanswered 5+ min outside the pane being viewed; a busy pane unchanged 15+ min; a vanished session | 0 tokens | mgr |
| Review sweeps | Every session's transcript delta and its sub-agents, plus risk.log, judged against each session's persona and launch prompt and the house rules. The regular model runs at :00/:30/:45, the deep model at :15. cos is reviewed too | headless `claude -p` only when there's new activity | mgr routes each `[session]` line to that session. A RISK wakes mgr at once; other findings wait for :20 |
| Check-in | Sessions owing work while idle, past due, or waiting on a prompt | one wake per hour | mgr nudges; cos redirects |
| mgr watch | mgr gone, a job not running exactly once, a stale snapshot (3 checks in a row) | 0 tokens | cos |

Watchers stay silent unless something is wrong. Don't use looping agent watchers: they wake the coordinator every minute and burn tokens.

## 5. Communication

| Channel | Used for |
|---|---|
| Chat in a pane | **Action items only:** decisions, things the owner must do, risks, corrections, answers. One open decision per message, with a recommendation. |
| SendMessage | Briefs, routed findings, worker reports. Never the owner's go. |
| `cos_state.md` | The live picture plus the **single open-calls list**. Nobody reminds the owner; an open call waits there. |
| `cos_log.md`, `.cos_tripwire/mgr_log.md` | What would otherwise be play-by-play in chat |
| `.cos_tripwire/review.log`, `risk.log` | Every sweep verdict; every outward call |
| `tools/cos_statrep.sh <win>` | A 12-line pane under cos showing `cos_statrep`, for updates that need no reply |
| `tools/cos_note.sh <pane>` | A short note pane just under the pane it's about |

Every finding starts with **VERIFIED** (the command or line that shows it) or **HYPOTHESIS**.

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
| `cos_mgrwatch.sh` | checks mgr and its 3 jobs | cos | background |
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
- `risk-log.sh` logs a `git push` but not an `ls`; `devnull-guard.sh` denies a redirect and allows a plain command.

**Not tested from the kit:**
- `cos_sweep.sh` and `wtchr_sweeps.sh` (they spend model tokens; the originals run live).
- `cos_tripwire.sh`, `cos_respawn.sh`, `cos_statrep.sh`, `cos_note.sh`, `agent_watch.sh` (only path changes from the live originals).
- The oversight plugin with a non-default `TEAM_ROOT` (the default path is the one in live use).
- A full `start_team.sh` with real Claude sessions.
- Linux (unsupported).

## 10. Adapting it
- **Owner:** the placeholders in `personas/cos.md` and `mgr.md`; your own rules in `house_rules.md`.
- **Models:** `SWEEP_MODEL`/`SWEEP_EFFORT`, `SWEEP_DEEP_MODEL`/`SWEEP_DEEP_EFFORT` (sweeps), `COS_*`/`MGR_*` (start_team.sh).
- **Outward CLIs:** add your own tools' write verbs to the patterns in `hooks/risk-log.sh`.
- **Root and session:** `TEAM_ROOT` (default `~/claude`), `TMUX_SESSION` (default `0`).
- **Linux:** not supported as shipped; see the Platform note at the top.

Author: Frank Pari.
