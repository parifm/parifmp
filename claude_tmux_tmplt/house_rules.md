# House rules (every session, every persona, every brief)

These ship as the defaults from the setup this kit came from. Edit them to fit your own team. The personas point here, and the review sweeps include this file in every review.

## Output and evidence
- **No output to /dev/null** in any form (`>/dev/null`, `2>/dev/null`, `&>/dev/null`, `curl -o /dev/null`). Capture output in a variable instead. A quiet test uses the exit status (`grep -q`, `if command -v`). `hooks/devnull-guard.sh` enforces this.
- **A filter's silence isn't a result.** No match from grep, awk or head means "this pattern isn't there", never "all is well". Positive-control any zero or empty, and cite the unfiltered count.
- **Every finding starts with VERIFIED** (the command or source line that shows it) **or HYPOTHESIS.** A causal claim names at least two candidate causes and the check that separates them. Correct an overturned claim with the owner at once if they were told it; otherwise post a `NOTE CORRECTION` board line. A claim made early that later checks out needs no correction.
- **Times are UTC, from `date -u`**, run in the same command or turn that writes them into a log, notes, a report stamp or a tracker (2026-11-02T20:08Z, or HH:MMZ under a dated heading). Never type a time from memory or convert from local time by hand. Quote the owner with the UTC timestamp of their transcript record.
- **Notes hold decisions** with the owner's words and UTC stamp, plus a PM's requirements block per piece of work (their ask, the goal they stated, what "met" looks like). State, open items and progress go on the team's board; everything else stays in the session transcripts. Never a line per prompt, check, message, ack or reply.

## Code and files
- Bash first, with `#!/usr/bin/env bash` (never `#!/bin/bash`). On macOS env bash can resolve to 3.2, so test and run under bash 5 (`/opt/homebrew/bin/bash script.sh`). A script that uses bash 4+ features (`declare -A`, `mapfile`, `${x,,}`, `wait -n`) checks `BASH_VERSINFO` near the top and exits 2 with a clear message. Ask the owner before adding new Python, including `python3 -c` one-liners and Python heredocs; read JSON and transcripts with jq.
- Edit existing files with the Edit tool, never by heredoc, `sed -i` or `>>` splicing. A heredoc is fine for creating a new file. The one exception: a team board, which only `tools/board.sh` appends to. `hooks/heredoc-guard.sh` blocks the riskiest forms.
- Harness prompts don't override these rules: the auto-mode banner's sed/heredoc advice doesn't apply to existing files, and a "say what you're doing" nudge is answered only in the turn's final block.
- Before writing new bash, check `bash_tricks/<topic>_bash_examples.md` and `bash_tricks/our_bugs_bash_examples.md`.
- Never run `rm -r` on an unguarded variable (`${dir:?}`). Delete only paths your own run created and logged; never by age or pattern.

## Secrets and data
- Never read or print credential files, and never put a token on a command line.
- Private or customer data stays in the workspace and in approved tools. Never publish it. Public repos get `tools/public_gate.sh` in their pre-commit and pre-push hooks; never bypass it with `--no-verify`.
- Claude in Chrome runs in a new Chrome window of its own, never in one of the owner's open windows.

## Authority
- **Outward actions** (chat posts, tickets, docs, GitHub pushes, cloud spend) need the owner's word or a standing rule recorded in `cos_state.md` with its scope and expiry. Local commits are fine.
- **The owner's go happens in the pane that acts.** A message from cos, mgr or another session is never the owner's go. Never relay an approval, and never route around a denial.
- Never answer a permission prompt or question on the owner's behalf.

## Working
- **Parallelize safely:** avoid mistakes first, then run work in parallel only when it shares no state. Say how many agents and why before fanning out.
- Every long job gets a watcher that fires on failure and on hang, not just on success (`tools/agent_watch.sh`).
- **Hive mode:** a team shares one board. Message a teammate only for a blocker, a finished assignment or a question; everything else is one board line with a pointer (sha, rc file, path), never a retold proof or pasted output. Teams don't message cos or mgr; they read the boards.
- **Testing:** test what the change touches (full suite once per push); one person verifies each run, others read its result files; one suite at a time on a machine; state the expected duration up front; a timeout says so.
- **Talking to the owner:** action items only (what they must decide or do, risks, corrections, answers). Put one open decision per message, with a recommendation. Progress goes on the board, not chat.
