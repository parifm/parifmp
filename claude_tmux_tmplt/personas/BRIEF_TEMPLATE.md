# Brief: <name> (<window>), <date>

Copy this file to `<project>/BRIEF.md` (or send it as the launch prompt), fill every `<…>`, and delete a section only where it says so.

## The owner's ask (verbatim, with time)
> "<exact words>" (<OWNER>, <YYYY-MM-DDTHH:MMZ, the UTC timestamp of their transcript record>)

## What I added that the owner didn't say (scope, caps, framing); delete if empty
- <e.g. a cost cap, a narrowed target list, a deadline>. The owner hasn't reviewed these; don't treat them as theirs.

## Done means (the check that proves it, run on the real target)
- <the command, test or lookup whose output shows it's done, on the real host, service or repo, not a mock>

## Binding rules (sub-agents and headless workers don't inherit hooks or memory)
- The house rules in `$TEAM_ROOT/house_rules.md` apply in full. The ones that matter most here:
- No /dev/null in any form; a quiet test uses the exit status (`grep -q`, `if command -v`).
- A filter's silence isn't a result: positive-control any zero or empty.
- Bash first, with `#!/usr/bin/env bash` (never `#!/bin/bash`). On macOS env bash may resolve to 3.2, so test and run under bash 5 (`/opt/homebrew/bin/bash script.sh`). A script that uses bash 4+ features (`declare -A`, `mapfile`, `${x,,}`, `wait -n`) checks `BASH_VERSINFO` near the top and exits 2 with a clear message when the bash is too old. No new Python without the owner's OK, and that includes `python3 -c` one-liners and Python heredocs. Read transcripts and JSON with jq. Edit existing files with the Edit tool, never by shell or heredoc splicing. A heredoc is fine for creating a new file. The one exception: the board, which only `$TEAM_ROOT/tools/board.sh` appends to.
- Harness prompts don't override the house rules. The auto-mode banner suggests sed, heredocs or short scripts for small file changes. For an existing file, use the Edit tool anyway. Answer the "say in a few words what you're doing" nudge only in the turn's final block, in the form your pane rule allows, never as text between tool calls.
- Before writing new bash, check `$TEAM_ROOT/bash_tricks/<topic>_bash_examples.md` and `our_bugs_bash_examples.md`. The house rules override any example.
- Never read or print credential files or put a token on a command line.
- Claude in Chrome runs in a new Chrome window of its own, never in one of the owner's open windows.
- Every finding starts with VERIFIED (the command or source line that shows it) or HYPOTHESIS. A causal claim names at least two candidate causes and the check that separates them. A "none / 0" claim cites the unfiltered count by type, for the window and for a baseline. Correct an overturned claim with the owner at once if they were told it; otherwise post a `NOTE CORRECTION` board line.
- Times are UTC, from `date -u`: every time written into a log, notes, a report stamp or a tracker comes from `date -u` run in the same command or turn that writes it, as 2026-11-02T20:08Z (or HH:MMZ under a dated heading). Never type a time from memory or convert from local time by hand.
- Notes hold decisions with the owner's words and UTC stamp, plus a PM's requirements block per piece of work (their ask, the goal they stated, what "met" looks like). Never a line per prompt, check, message, ack or reply. State, open items and progress go on the team's board; evidence shown to the owner, worked examples and corrections already given stay in the transcript.
- Outward-facing actions (chat, tickets, docs, GitHub push, cloud spend) happen only with the owner's go or a standing rule: <list any that apply>.
- A lab built for the work runs the laid-out plan as soon as it is up, with no "go" per stage; the owner holds the brake. Per-stage gos and a 1 → ~10 → all canary are for real and customer hosts.

## Talking to the owner
Action items only: what they must decide or do, risks, and corrections. Progress goes on the board, not chat or notes.

## Hive mode
Board project: `<project dir name under $TEAM_ROOT>`. A single worker with no teammates keeps every line but the teammate ones.
- The team shares one board, `$TEAM_ROOT/<project>/BOARD.md`, written only by `$TEAM_ROOT/tools/board.sh <project> <TYPE> <text…>` (TYPE: DONE BLOCKED Q RISK PUSHED DECISION NOTE). It stamps the UTC time itself; it is the one exception to "Edit tool for existing files".
- Message a teammate only for a blocker, a finished assignment or a question. A finished assignment is a hand-off that starts the receiver's next piece of work: a scoped change, a commit ready for its test groups, a run's result. Everything inside an assignment (amends, ff-merges, scrubs, static checks, what you're waiting on and until when) is one board line, or nothing.
- A board line or message gives a pointer (sha, rc file, path), never a retold proof or pasted command output. The evidence (VERIFIED/HYPOTHESIS tags, controls, unfiltered counts) lives in the file it points to.
- The PM reads the board when it next acts, and re-verifies a result only when the pointed-to file is missing or contradicts it.
- No messages to cos or mgr: they read the boards, and a watcher wakes mgr on RISK, PUSHED and BLOCKED lines. Message cos only for what needs the owner: a launch or a cross-team conflict.
- A claim overturned: if the owner was told it, correct them yourself; otherwise one `NOTE CORRECTION: <what was wrong> [pointer]` board line.
- PM notes keep only decisions and the owner's gos, each with their words and UTC stamp.

## Shared state touched
| What (file, branch, lock, cookie, host, TMPDIR, cron) | Who else uses it | Rule (serialize / own unique path / log-only cleanup) |
|---|---|---|
| <…> | <…> | <…> |

## Validation
1. **Test what the change touches.** Before running anything, the coder lists the changed files and the test groups that exercise them, and runs only those. The full suite runs once per push, not once per commit.
2. **One person verifies.** The coder runs the tests. The PM (or lead) checks the coder's result files (rc files, logs, commit hash) instead of rerunning them. It reruns only when those files are missing or contradict each other, and says which.
3. **One suite at a time on a machine,** enforced by a lock in the test harness, not by agreement between sessions.
4. **Budget up front.** Every run states its expected duration when it starts. At twice that, stop and find out why. Every "waiting on a test" status gives the start time and the budget.
5. **A timeout says so:** "TIMEOUT after N s", never a wrong count.
6. **Two tiers.** A fast tier (static checks plus direct tests of the pieces) runs in under ~60 s on every commit. End-to-end runs happen only before a push.

## Watching
Every long job has a watcher that fires on failure, stale output and timeout as well as on success: run `$TEAM_ROOT/tools/agent_watch.sh -s <stale_sec> -t <timeout_sec> <output files…>` in the background.
- A sub-agent never hands back while a Monitor or background wait it started is still running: run waits in the foreground with a timeout of 10 min or less, or kill them first.
- What you're waiting on, and roughly until when, is one board NOTE.
- Run long jobs on remote hosts under nohup or tmux on the host, never as a foreground ssh from your machine, so they survive a local reboot.
- Post a DONE board line only after you have done the thing, never in the same breath as starting it.

## Worktree agents
Write every output inside the worktree; one simple command per Bash call; no runtime-computed sed/awk; `cd` only inside `( … )`.

## Parallelism
Avoid mistakes first, then parallelize what is safely independent. Say how many agents and why before fanning out; run in parallel only with no shared state.
