# Claude Code: field notes

Things that we measured or hit while we ran Claude Code sessions in 2026-08 to 2026-10. Each note is from one version at one time. Test again before you rely on it.

## 1. `grep` in the Bash tool is a shell function, not the system grep

- `type grep` in the Bash tool shows a function from Claude Code's shell snapshot. It runs a bundled ugrep with `-G --ignore-files --hidden -I` and excludes `.git` and similar directories.
- **A measured difference:** `printf '(a.md)\n' | grep -o '([^()]*\.md)'` prints nothing in the function. `/usr/bin/grep` prints `(a.md)`. The trigger is a literal parenthesis next to a bracket expression that contains parentheses.
- Recursive searches through the function skip what `.gitignore` lists, and skip binary files.
- **Scope:** only the Bash tool's own shell. The function is not exported, so scripts, test suites and hooks get the system grep.
- **How to apply:** when a grep in the Bash tool finds nothing where something must be, run it again with `command grep`. Print a count beside each filtered list.

## 2. Commands and skills are deduplicated by real path

- Claude Code removes duplicates of command and skill files by real path, and keeps the first name in alphabetical order. A symlink alias makes one of the two names disappear.
- A plain copy, or a one-line pointer command ("read `${CLAUDE_PLUGIN_ROOT}/commands/view.md` and follow it"), registers each name.
- Check what is registered: `claude -p "say hi" --plugin-dir <plugin> --output-format stream-json --verbose`. The first line lists `slash_commands`.

## 3. An approved command line is stored as a permission rule, with its secrets

- When you approve a Bash command, Claude Code can store the command string as an allow rule in `~/.claude/settings.json` or `<project>/.claude/settings.local.json`.
- A credential on that command line is then in a settings file that each session reads. We found 7 copies of one API key in each file, from approved `curl -H 'Authorization: ...'` calls.
- A second path: a `cat` of a credentials file puts the secret into the session transcript.
- **How to apply:**
  - Do not put a secret on a command line. Let the process read it: an environment variable that the tool reads, or `curl --config -` with the config on stdin.
  - Do not print a credentials file.
  - When you audit an exposure, scan the settings files and the transcripts, not only git. Compare hashes; do not print the secret.

## 4. A message typed during a turn is not a `user` record in the transcript

- In `~/.claude/projects/<project>/<session>.jsonl`, a message that the user typed while the agent was in a turn is stored as `{"type":"queue-operation","operation":"enqueue","content":"..."}` plus an `attachment` record of type `queued_command`.
- A `jq` filter on `type=="user"` does not find it. Two agents once "proved" with that filter that an approval did not exist.
- **How to apply:** before you say "the user did not say X", grep the raw file for the text, and run a positive control on a line that you know is there.

## 5. tmux and Claude Code sessions

- New pane: `tmux split-window -h|-v -t "$TMUX_PANE" -P -F '#{pane_id}'`. Start a session with a first prompt: `tmux send-keys -t %N "claude '<prompt>'" Enter`.
- `~/.claude/sessions/<pid>.json` maps a process to its session id and name.
- To move a session into a pane: `/exit` it in its terminal, then `claude --resume <sessionId>` in the pane. Do not run two processes on one session.
- A session can compact itself: `tmux send-keys -t "$TMUX_PANE" /compact Enter` during a turn puts the command in the queue, and it runs when the turn ends.

## 6. Send keys to a session that uses vim input mode

- Escape puts the input in NORMAL mode. The next text is read as vim commands. Escape, then `/exit`, then Enter once submitted the prompt "t".
- To stop a runner: `tmux send-keys C-c`, three times, about 0.7 seconds apart.
- To type a prompt: use `send-keys -l` while the status line shows INSERT. Read the pane before you send Enter.

## 7. A fenced session still had the browser tools

- `--strict-mcp-config` did not remove the built-in Chrome tools. They operate the user's logged-in browser.
- For a fenced session, add `--no-chrome --disallowedTools 'mcp__claude-in-chrome'`.
- Verify from the transcript: the `deferred_tools_delta` attachment must hold no `mcp__` names.
- A deny rule that you add to the settings during a session cannot be shown to reach a session that already runs. Start the session again.
