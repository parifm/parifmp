# Dependencies

What you need before `./install.sh --go` and `./start_team.sh` work, and what each part is for. "Tested with" is the version on the machine the kit runs on today (2026-11-21); no older version was tried, so a minimum is not known.

## 1. Platform (required; the scripts refuse to run anywhere else)

| Need | Why | Check |
|---|---|---|
| macOS | The scripts use BSD forms of `date` (`-j`, `-r`) and `stat` (`-f`). `install.sh` and `start_team.sh` refuse another system. | `uname -s` prints `Darwin` |
| Apple Silicon Homebrew in `/opt/homebrew` | 20 scripts start with `#!/opt/homebrew/bin/bash`, and the personas launch jobs with that path by name. An Intel Mac keeps Homebrew in `/usr/local`, so the scripts fail there with "bad interpreter". | `ls /opt/homebrew/bin/bash` |

Tested with macOS 15.8 on arm64. Linux is not supported; the top of `README.md` says what a port would change.

## 2. Command-line tools (required)

`install.sh` checks the first five and refuses to continue when one is missing.

| Tool | Install | Used by | Tested with |
|---|---|---|---|
| bash 5 | `brew install bash` | every script (macOS `/bin/bash` is 3.2; the scripts that need bash 4+ features check the version and exit 2) | 5.3 |
| tmux | `brew install tmux` | the workspace itself: `start_team.sh`, snapshot and restore, respawn, tripwire, statrep and note panes | 3.8 |
| jq | `brew install jq` | nearly every script: the session registry, transcripts, the restore manifest, the hooks' input | 1.7.1 |
| `gtimeout` | `brew install coreutils` | `tools/cos_sweep.sh` puts a time limit on each headless review | coreutils 9.12 |
| `shasum` | part of macOS | `tools/cos_tripwire.sh`, `tools/cos_tmpltdrift.sh` | as shipped |
| `pgrep`, `ps` | part of macOS | job and session checks (`cos_mgrwatch.sh`, `cos_restore.sh`, `cos_selfrestart.sh`) | as shipped |

One line for the Homebrew part: `brew install bash tmux jq coreutils`

## 3. Claude Code (required)

| Need | Why |
|---|---|
| The `claude` CLI, signed in | Every pane is a `claude` session, and each review sweep is a headless `claude -p` run. |
| A plan with room for several sessions at once plus the sweeps | A small team is cos, mgr and one to four workers, with a headless review every 15 minutes while there is new activity, and one forked check per session about every 6 steps (the oversight plugin). |
| Access to the models the kit names | Defaults: `opus` for cos and mgr (`start_team.sh`), `claude-opus-5-5` for the regular sweeps and the retry, `claude-fable-5-1` for the :15 sweep. Change them with `COS_MODEL`, `MGR_MODEL`, `SWEEP_MODEL`, `SWEEP_DEEP_MODEL`, `SWEEP_RETRY_MODEL` and the matching `*_EFFORT` variables if your account has other models. |

Tested with Claude Code 2.1.329. The kit depends on these Claude Code features, so a much older version, or a later one that changes them, will break a part of it:

| Feature | What depends on it |
|---|---|
| Launch flags `-n`, `--model`, `--effort`, `--settings`, `--append-system-prompt`, `--append-system-prompt-file`, `--resume`, `--system-prompt-snapshot off` | every launch, respawn and restore line |
| Headless mode: `claude -p --tools ""` | the review sweeps |
| The session registry, `~/.claude/sessions/<pid>.json` (fields `name`, `sessionId`, `status`, `tmux`, `pid`, `cwd`) | tripwire, check-in, snapshot, respawn, restore, sweeps: they find sessions there, never by pane position |
| Transcripts under `~/.claude/projects/<launch folder>/<session id>.jsonl` | the sweeps and `tools/owner_said.sh` |
| PreToolUse hooks in `~/.claude/settings.json` | the three guards in `hooks/` (and the two in `claude_kb/`) |
| Plugins loaded through `CLAUDE_CODE_PLUGIN_DIRS`, with hook modules | `oversight_plugin/` |
| Messages between sessions (`SendMessage`, `ListAgents`) | cos and mgr, mgr's routed findings, teammates |
| Session crons (`CronCreate`, `CronList`) | mgr's hourly check-in |
| Background Bash commands that wake the session when they exit | every watcher: tripwire, sweeps, board watch, mgr watch, the HANDOFF watcher |

Node.js is **not** needed to run the kit: Claude Code loads the plugin's `.mjs` module itself. `node --check` is used only to test the plugin after an edit.

## 4. Optional parts

| Part | Needs | Without it |
|---|---|---|
| Public-repo gate and watch (`tools/public_gate.sh`, `tools/public_watch.sh`) | `git`; for the watch, ssh access to `git@github.com:<you>/<repo>.git` with a key loaded in the agent | Skip them. Nothing else uses them. |
| Memory database (`claude_kb/`) | PostgreSQL with the pgvector (`vector`) and `pg_trgm` extensions, running locally; `pigz`; `curl`; ollama with the model `qwen3-embedding:0.6b` for `kb ask` and embeddings | **Delete the two kb rules in `house_rules.md`**, or every session is bound by a rule it can't keep. `kb search` works without ollama. Tested with PostgreSQL 18. |
| Lab worker example (`personas/labWorker.example.md`) | a cloud account and its CLI (the example is written for the `oci` CLI), and a spend cap you set | Don't use that persona. |
| Blind reviewer example (`personas/reviewer.example.md`) | `git`, and a second clone of the project outside the team root | Don't use that persona. |
| Claude in Chrome | the browser extension | Only the one house rule about it applies. |

## 5. What the kit writes on your machine

| Where | What |
|---|---|
| `$TEAM_ROOT` (default `~/claude`) | `tools/`, `personas/`, `bash_tricks/`, `claude_kb/`, `house_rules.md`, the state files (`cos_state.md`, `cos_sessions`, `cos_watch.tsv`, `cos_log.md`), and at run time `.cos_tripwire/`, `.oversight/`, `restore/` and one `<project>/BOARD.md` per team |
| `~/.claude/hooks/` | the three guards and the heredoc-guard tests |
| `~/.claude/settings.json` | **Nothing by itself.** `install.sh` prints the hook blocks and you merge them. |

`install.sh` never overwrites a file that exists. Sessions must start from `$TEAM_ROOT`, because Claude Code keys its memory and transcripts to the launch folder.

## 6. Check before you install

```bash
for c in tmux jq claude gtimeout shasum git; do
  if p=$(command -v "$c"); then echo "ok       $c  $p"; else echo "MISSING  $c"; fi
done
/opt/homebrew/bin/bash -c 'echo "bash ${BASH_VERSION}"'
./install.sh        # the dry run: it repeats the required checks and prints the plan
```
