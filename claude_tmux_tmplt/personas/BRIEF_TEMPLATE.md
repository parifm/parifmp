# Brief: <name> (<window>), <date>

Copy this file to `<project>/BRIEF.md` (or send it as the launch prompt), fill every `<…>`, and delete a section only where it says so.

## The owner's ask (verbatim, with time)
> "<exact words>" (<OWNER>, <YYYY-MM-DD HH:MM>)

## What I added that the owner didn't say (scope, caps, framing); delete if empty
- <e.g. a cost cap, a narrowed target list, a deadline>. The owner hasn't reviewed these; don't treat them as theirs.

## Done means (the check that proves it, run on the real target)
- <the command, test or lookup whose output shows it's done, on the real host, service or repo, not a mock>

## Binding rules (sub-agents and headless workers don't inherit hooks or memory)
- The house rules in `$TEAM_ROOT/house_rules.md` apply in full. The ones that matter most here:
- No /dev/null in any form; a quiet test uses the exit status (`grep -q`, `if command -v`).
- A filter's silence isn't a result: positive-control any zero or empty.
- Bash first (bash 5); no new Python without the owner's OK. Edit existing files with the Edit tool, never by shell or heredoc splicing. A heredoc is fine for creating a new file.
- Before writing new bash, check `$TEAM_ROOT/bash_tricks/<topic>_bash_examples.md` and `our_bugs_bash_examples.md`. The house rules override any example.
- Never read or print credential files or put a token on a command line.
- Every finding starts with VERIFIED (the command or source line that shows it) or HYPOTHESIS. A causal claim names at least two candidate causes and the check that separates them. A "none / 0" claim cites the unfiltered count by type, for the window and for a baseline. Retract an overturned claim to the owner and cos at once.
- Outward-facing actions (chat, tickets, docs, GitHub push, cloud spend) happen only with the owner's go or a standing rule: <list any that apply>.

## Talking to the owner
Action items only: what they must decide or do, risks, and corrections. Progress goes in your project's notes, not chat. A turn that only handled another session's message, and needs nothing from the owner, ends with exactly "(logged)".

## Shared state touched
| What (file, branch, lock, cookie, host, TMPDIR, cron) | Who else uses it | Rule (serialize / own unique path / log-only cleanup) |
|---|---|---|
| <…> | <…> | <…> |

## Validation
Targeted tests per agent; the full suite runs once, at integration.

## Watching
Every long job has a watcher that fires on failure, stale output and timeout as well as on success: run `$TEAM_ROOT/tools/agent_watch.sh -s <stale_sec> -t <timeout_sec> <output files…>` in the background.
- A sub-agent never hands back while a Monitor or background wait it started is still running: run waits in the foreground with a timeout of 10 min or less, or kill them first.
- Tell cos what you're waiting on and roughly when.
- Run long jobs on remote hosts under nohup or tmux on the host, never as a foreground ssh from your machine, so they survive a local reboot.
- Tell cos something is done only after you have done it.

## Worktree agents
Write every output inside the worktree; one simple command per Bash call; no runtime-computed sed/awk; `cd` only inside `( … )`.

## Parallelism
Avoid mistakes first, then parallelize what is safely independent. Say how many agents and why before fanning out; run in parallel only with no shared state.
