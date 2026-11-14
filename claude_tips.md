# 50 tips for working with Claude

Each tip has the reason it helps.

## Framing the ask

1. Ask Claude to state the goal before long work starts.
   - A wrong goal shows in one line, before it costs hours.
2. Mark a question as a question ("no changes, just a question").
   - Claude tends to act; the mark prevents unwanted edits.
3. Discuss the design first, and allow code only after you agree.
   - Changing a plan is cheap; changing built code is not.
4. State the mode: "prove it" or "fast, no ceremony".
   - Claude cannot tell how much checking you want, and both wrong guesses waste time.
5. State the size of the answer: a general idea or a full investigation.
   - Without it, a simple question can start a long investigation.
6. State binding preferences as rules at the start.
   - A preference reads as optional and loses to the model's defaults.
7. Say what "done" means.
   - Claude then stops at the right point and does not claim completion early.
8. Name what is out of scope.
   - A nearby, richer example pulls the work beyond the ask.
9. Tell Claude who the audience is.
   - Wording, depth and what must be removed all depend on the reader.
10. Give the workload and environment facts early.
    - One missing fact can reverse a risk analysis.

## Evidence and verification

11. Ask how a hypothesis can be validated before any change is made.
    - A change based on a guess hides the true cause.
12. Ask for the prediction before a command runs, then compare.
    - A stated prediction makes a surprise visible.
13. Ask for a positive control before you accept a zero or an empty result.
    - A search that cannot find a known item proves nothing about a missing one.
14. Demand a source for each claim: a full URL or a file and line. Open it.
    - Sources make false claims cheap to catch.
15. Ask Claude to check each quote and figure against its source before it reports them.
    - Models tidy and paraphrase without notice.
16. Ask for denominators: "2 of 147", not "only 2".
    - A count without its total hides how much was checked.
17. Ask "what did you not read or not run?" at the end of a report.
    - Gaps then show as gaps, not as coverage.
18. Bring raw output back unfiltered, and let Claude process it locally.
    - Filters applied at the source drop the evidence you did not predict.
19. Change one variable per test.
    - With several changes, you cannot tell which one worked.
20. Use a canary: one target, then a few, then all.
    - A fault stays small and its cause stays clear.
21. Ask for the raw data once more when a result matches your theory exactly.
    - A flattering result gets less scrutiny, so errors survive there.
22. Ask for a pre-mortem on a risky change: how it fails and what would show it.
    - Failure signs are defined before they are needed.

## Scope, cost and time

23. Ask for cost first, then benefit, before you approve an expensive mode.
    - The two answers together show whether a cheaper design is enough.
24. Give budgets as numbers: money, minutes, hosts.
    - A number can be obeyed; "be reasonable" cannot.
25. Give the time budget before the work starts.
    - Claude sizes the plan to the budget; a late budget wastes the first plan.
26. Ask for a stop condition on each long job: budget, timeout, and what the timeout prints.
    - A job then cannot hang or fail silently.
27. Ask for the one-line version before any design.
    - Many problems disappear with a different invocation, with no new code.
28. Have a script built once in place of repeated in-context work.
    - A script is fast, repeatable and free of model variance.

## Decisions and conversation

29. Ask for the cause of an error, not an apology.
    - The cause can be fixed; an apology changes nothing.
30. State your own share of a mistake.
    - Claude then reports its share plainly, with less defence.
31. Invite pushback in plain words, and accept it when it has a reason.
    - Models lean toward agreement unless disagreement is clearly welcome.
32. Ask "what would change your view?" with each recommendation.
    - It separates a firm conclusion from a default.
33. Ask for the assumptions at the start of a design, and strike the wrong ones.
    - Hidden assumptions are the usual source of a wrong build.
34. Show an example when words fail.
    - One example fixes a format faster than several rounds of description.
35. Give short, explicit picks for decisions.
    - A clear pick cannot be misread.
36. Answer pending questions by number.
    - One general "yes" can attach to the wrong question.
37. Say when your silence means "still open".
    - Claude may record an unanswered option as a refusal.
38. Restate the target design in one line during a long design conversation.
    - Details then attach to the target, not to the latest draft.
39. Ask which choices were Claude's and which were yours.
    - Attribution drifts, and a wrong attribution buries options.
40. Keep the fix in the same message as the criticism.
    - Criticism without direction produces a guess.

## Models, context and sessions

41. Use a cheap model for collection and a strong model for judgment.
    - Each model does the work it is good at, for less cost.
42. Start at low or medium effort, and raise it only when a result is thin.
    - High effort can add unneeded work and side tracks.
43. Record the model and effort next to results you judge good or bad.
    - You build your own evidence for later choices.
44. Use a fresh session for each topic.
    - A crowded context lowers accuracy and mixes topics.
45. Use a targeted compact with a keep-list.
    - You choose what survives, not the summarizer.
46. Use a fresh, blind session to review important work.
    - A reviewer without the author's context finds different faults.
47. Tell an orchestrating session when you close or change something yourself.
    - It otherwise spends effort to infer the state, or acts on a stale one.

## Rules and review

48. Review the standing rules on a schedule.
    - Rules pile up, conflict and cost context on every turn.
49. Retire a rule that costs more than it saves.
    - A rule that causes more errors than it prevents is a net loss.
50. End a long session with "what did I do that cost you time?"
    - It shows where your prompts caused extra work, which you cannot see from outside.
