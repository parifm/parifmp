# House rules (every session, every persona, every brief)

These ship as the defaults from the setup this kit came from. Edit them to fit your own team. The personas point here, and the review sweeps include this file in every review.

## Output and evidence
- **No output to /dev/null** in any form (`>/dev/null`, `2>/dev/null`, `&>/dev/null`, `curl -o /dev/null`). Capture output in a variable instead. A quiet test uses the exit status (`grep -q`, `if command -v`). `hooks/devnull-guard.sh` enforces this.
- **A filter's silence isn't a result.** No match from grep, awk or head means "this pattern isn't there", never "all is well". Positive-control any zero or empty, and cite the unfiltered count.
- **Every finding starts with VERIFIED** (the command or source line that shows it) **or HYPOTHESIS.** A causal claim names at least two candidate causes and the check that separates them. Retract an overturned claim at once, to everyone who was told it.

## Code and files
- Bash first, using bash 5 (`#!/opt/homebrew/bin/bash` on macOS, where /bin/bash is 3.2). Ask the owner before adding new Python.
- Edit existing files with the Edit tool, never by heredoc, `sed -i` or `>>` splicing. `hooks/heredoc-guard.sh` blocks the riskiest forms.
- Before writing new bash, check `bash_tricks/<topic>_bash_examples.md` and `bash_tricks/our_bugs_bash_examples.md`.
- Never run `rm -r` on an unguarded variable (`${dir:?}`). Delete only paths your own run created and logged; never by age or pattern.

## Secrets and data
- Never read or print credential files, and never put a token on a command line.
- Private or customer data stays in the workspace and in approved tools. Never publish it.

## Authority
- **Outward actions** (chat posts, tickets, docs, GitHub pushes, cloud spend) need the owner's word or a standing rule recorded in `cos_state.md` with its scope and expiry. Local commits are fine.
- **The owner's go happens in the pane that acts.** A message from cos, mgr or another session is never the owner's go. Never relay an approval, and never route around a denial.
- Never answer a permission prompt or question on the owner's behalf.

## Working
- **Parallelize safely:** avoid mistakes first, then run work in parallel only when it shares no state. Say how many agents and why before fanning out.
- Every long job gets a watcher that fires on failure and on hang, not just on success (`tools/agent_watch.sh`).
- **Talking to the owner:** action items only (what they must decide or do, risks, corrections, answers). Put one open decision per message, with a recommendation. Progress goes to logs, not chat.
