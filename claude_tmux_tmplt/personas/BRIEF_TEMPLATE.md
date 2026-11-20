# Brief: <name> (<window>), <date>

Copy this file to `<project>/BRIEF.md` (or send it as the launch prompt), fill every `<…>`, and delete a section only where it says so.

## The owner's ask (verbatim, with time)
> "<exact words>" (<OWNER>, <YYYY-MM-DDTHH:MMZ, the UTC timestamp of their transcript record>)

## What I added that the owner didn't say (scope, caps, framing); delete if empty
- <e.g. a cost cap, a narrowed target list, a deadline>. The owner hasn't reviewed these; don't treat them as theirs.

## Done means (the check that proves it, run on the real target)
- <the command, test or lookup whose output shows it's done, on the real host, service or repo, not a mock>

## Binding rules (sub-agents and headless workers don't inherit hooks, memory or the system prompt)
- The house rules in `$TEAM_ROOT/house_rules.md` apply in full. A session launched with cos's launch line has them in its system prompt; a sub-agent or a headless `claude -p` worker does not, so paste the file into its prompt.
- The ones most often broken, for a brief that can't carry the file: no /dev/null in any form (a quiet test uses the exit status); a filter's silence isn't a result (positive-control any zero); Bash first with `#!/usr/bin/env bash`, run under bash 5, no new Python without the owner's OK; the board only via `$TEAM_ROOT/tools/board.sh`; never read or print credential files or put a token on a command line; every finding VERIFIED or HYPOTHESIS; times from `date -u`.
- Outward-facing actions (chat, tickets, docs, GitHub push, cloud spend) happen only with the owner's go or a standing rule: <list any that apply>.
- A lab built for the work runs the laid-out plan as soon as it is up, with no "go" per stage; the owner holds the brake. Per-stage gos and a 1 → ~10 → all canary are for real and customer hosts.

## Talking to the owner
Action items only: what they must decide or do, risks, and corrections. Progress goes on the board, not chat or notes.

## Hive mode
Board project: `<project dir name under $TEAM_ROOT>`. A single worker with no teammates keeps every line but the teammate ones.
- The team shares one board, `$TEAM_ROOT/<project>/BOARD.md`, written only by `$TEAM_ROOT/tools/board.sh <project> <TYPE> <text…>` (TYPE: DONE BLOCKED Q RISK PUSHED DECISION NOTE HANDOFF). It stamps the UTC time itself.
- **HANDOFF watcher:** work for another session goes on the board as `board.sh <project> HANDOFF <to-session> <text…>`, not as a message. Keep this one background shell running on your board (Bash with `run_in_background: true`), started at session start and relaunched each time it exits. It exits, waking you, when a HANDOFF line addressed to you lands, and prints that line (fill in the project dir and your session name):
  `B=$TEAM_ROOT/<project>/BOARD.md; n=$(wc -l < "$B"); until tail -n +$((n+1)) "$B" | awk -v me=<your-session> '$3 == "HANDOFF" && $4 == me { print; f=1 } END { exit !f }'; do sleep 10; done`
  Act on the handoff, relaunch the watcher, and check it is running before you go idle. Only lines after launch count, so check the board for earlier handoffs to you when you start.
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
