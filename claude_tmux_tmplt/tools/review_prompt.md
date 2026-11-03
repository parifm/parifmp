# Code review prompt (general)

A general code-review prompt for any project; no persona carries it by default. It guards against the mistakes the review sweeps flag most often, and borrows from Claude Code's built-in /code-review recipe: three-state verify rules, independent angles, removed-behaviour and cross-file passes, a gap sweep, a separate verifier, unchanged lines in touched functions, quoted-rule conventions, short_summary plus dedup, and a note of what ran.

Fill the `<…>` placeholders, then send everything inside the fence. Leave out the removed-behaviour pass when there is no `<OLD_REF>`.

```
Review <TARGET: files/dirs, or "everything changed since <ref>"> at commit <SHA> on branch <BRANCH>,
together with the inputs it consumes (<config/data/example files>). Hunt for missed edge cases,
race conditions, and unhandled null, empty or error states. Treat the code as guilty of hiding a
subtle bug until proven innocent.

Ground rules
- Read only. Do not modify code, run tests, or touch any host. This is a review done in context.
- Pin the commit with `git rev-parse HEAD` first. Every line number refers to that SHA.
- Read every in-scope file in full. Keep a coverage ledger: file, total lines, line ranges read.
  If your context is compacted, re-read before you cite a line. "No issues in X" is allowed only
  when the ledger shows all of X was read.
- For a diff-scoped review, bugs in unchanged lines of a touched function are in scope: read the
  whole enclosing function for every hunk.
- Platforms and environments to reason about: <e.g. bash 3.2 and 5.x, GNU and BSD tools,
  gawk and mawk, Linux only>.
- Project rules that apply: <paths to CLAUDE.md, briefs or style rules, or "none">.

Phase 1: find candidates, one pass per angle
Run each angle below as its own pass and record its candidates before starting the next. Don't let
one angle's conclusion suppress another's: if two angles flag the same line for different reasons,
keep both until the dedup.
- A. Line by line. For every line ask: what input, state, timing or platform makes it wrong?
  Look for inverted conditions, off-by-one, empty or unset values reaching destructive or
  path-building code, unquoted expansion and word splitting, wrong-variable copy-paste, errors
  swallowed in pipelines, subshells or command substitution.
- B. Removed behaviour (when <OLD_REF> is given). For every line the new code deletes or
  replaces relative to <OLD_REF>, name the invariant or behaviour it enforced, then find where
  the new code enforces it again. If you can't find it, that's a candidate: a dropped guard or
  error path, a narrowed validation, a deleted test that covered a real case.
- C. Cross-file contracts. For each function, find its callers and callees and check for new
  preconditions, changed return shapes or exit codes, new failure modes, and ordering
  dependencies. Also check what the code assumes about its inputs (formats, optional fields,
  empty or duplicate entries, ordering) against what those inputs actually allow.
- D. Concurrency and lifecycle: background jobs, waits on the wrong pid, fifos and pipes,
  SIGPIPE, shared temp files, signal and trap ordering, time-of-check vs time-of-use, kills by
  name or pattern, cleanup that never runs on failure, partial writes.
- E. Language and platform pitfalls for <LANGUAGE>, plus boundaries: zero, one, max, duplicate
  entries, whitespace and special characters, missing trailing newline, very long inputs,
  malformed or extra or missing fields, clock and timezone.
- F. Project rules. Flag a violation only when you can quote the exact rule (file and text) and
  the exact line that breaks it. No style preferences or "spirit of the doc" inferences.
For every candidate, give a concrete failure scenario (this input or state, then this wrong
output or crash) and show the working for any count or arithmetic.

Phase 2: dedup and verify
- Dedup: same defect, same location, same reason means one record. Keep the one with the most
  concrete failure scenario and list the angles that found it.
- Verify each remaining candidate. Prefer a fresh sub-agent or a second session that gets only
  the files and the candidate, not your reasoning. If that isn't available, verify it yourself
  and say so in the summary. Each gets exactly one verdict:
  - CONFIRMED: you can name the inputs or state that trigger it and the wrong result. Quote the
    line. Tag VERIFIED.
  - PLAUSIBLE: the mechanism is real but the trigger is uncertain (timing, environment,
    config). State what would confirm it. Tag HYPOTHESIS.
  - REFUTED: the code doesn't say that, it is provably impossible (type, constant or
    invariant: show it), a guard already handles it (cite the guard's line), or it is pure style
    with no observable effect.
- PLAUSIBLE by default. Do not refute a candidate for being "speculative" or "depends on
  runtime state" when that state is realistic: races, empty or unset values on a
  rare-but-reachable path (error handler, cold start, missing optional field), boundaries the
  code doesn't exclude, partial failures and retries, a pattern that lost its anchor.
- Keep CONFIRMED and PLAUSIBLE. Drop REFUTED from the findings, but list each one in the
  summary with the line that refutes it.
- Set severity only after the verdict, never before the check that decides it.

Phase 3: sweep for gaps
Re-read the code once more as a fresh reviewer who has the verified list, looking only for
defects not already on it. Don't re-confirm anything. Focus on what first passes miss: moved
or extracted code that dropped a guard or anchor, a lock or critical section that shrank,
setup and teardown that don't match, config defaults that flipped, predicates with side
effects. Add at most 8 new candidates and verify them as in Phase 2. If there's nothing new,
add nothing; don't pad.

Output: <PATH>/review_<SHA7>.jsonl, one JSON object per line:
  {"id", "file", "line", "line_text" (quoted exactly, so the line can be found again after
   edits), "category" (edge-case|race|null-error|contract|removed-behavior|portability|
   rules|other), "severity" (high|med|low), "verdict" (CONFIRMED|PLAUSIBLE),
   "tag" (VERIFIED|HYPOTHESIS), "summary", "short_summary" (the claim alone, at most 60
   characters), "failure_scenario", "confirm_by" (for PLAUSIBLE: what would confirm it),
   "angles" (the angles that found it), "related" (other ids or file:line)}
Rank the records most severe first.
Last line: a summary object {"type":"summary", "sha", "files": <coverage ledger>,
  "findings": <count by severity>, "refuted": [{"candidate", "file:line", "refuting_line"}],
  "method": <what actually ran: angles run, who verified (sub-agent, second session or self),
  whether the gap sweep ran>, "stamp": <from `date -u`>}.

Delivery
- After writing, validate: `jq -c . <file> | wc -l` must equal the record count you report.
  Announce delivery only after that check returns.
- Send <RECIPIENT> the path, the SHA, the severity counts and the method line, plus the
  high-severity summaries word for word. Nothing else in the message.
```
