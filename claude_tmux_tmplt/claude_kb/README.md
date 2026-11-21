# claude_kb: the team's memory in Postgres (optional)

Claude Code keeps a project's memory as files under `~/.claude/projects/<project>/memory/`. With many sessions writing there, files get duplicated, overwritten and lost. This part of the kit moves memory into one Postgres table that every session reaches the same way, through one script. Nothing else in the kit needs it: a team works without it, and `install.sh` copies it but turns nothing on.

## What is here
| File | Purpose |
|---|---|
| `kb` | the only way in or out: `init`, `load`, `search`, `ask`, `show`, `history`, `list`, `add`, `edit`, `retire`, `embed`, `backup`, `prune` (run it with no arguments for the usage) |
| `kb_schema.sql` | one table, `memory`: every version of every memory, one current row per name; keyword, fragment and vector indexes |
| `kb-guard.sh` | PreToolUse hook: refuses a Bash command that names `psql`, `createdb`, `dropdb`, `pg_dump` or `pg_restore` together with the kb database |
| `memory-guard.sh` | PreToolUse hook: refuses a write into the team root's `memory/` folder, except `MEMORY.md` (the pointer page) and `memory/arxiv/` |

## Requirements
- PostgreSQL with the `vector` (pgvector) and `pg_trgm` extensions, running locally, and the current user able to create a database.
- `pigz` for backups.
- ollama with the embedding model `qwen3-embedding:0.6b` (1024 dimensions; `kb_schema.sql` fixes that size, so another model needs a matching column). `kb search` works without ollama; `kb ask` and embeddings do not.

## Turn it on
1. `$TEAM_ROOT/claude_kb/kb init` creates the database and the table. It drops nothing.
2. `kb load` imports the memory files that already exist (`memory/*.md`, `memory/arxiv/*.md`, `notes/*.md` under the team root's Claude Code project folder), then `kb embed`.
3. Merge the two hooks from the second block that `install.sh` prints into `~/.claude/settings.json`.
4. Replace the content of the project's `memory/MEMORY.md` with a short pointer page: memories live in the kb, how to recall (`kb search`, `kb ask`, `kb show`), how to save (`kb add`, `kb edit`, `kb retire`).
5. Add these two lines to `house_rules.md`, under "Secrets and data", and restart the sessions so the rules reach their system prompts:
   ```
   - **Memories live in Postgres (db kb) and are reached only through `claude_kb/kb`** (search, ask, show, list, add, edit, retire, backup, prune). Never psql or pg_dump against db kb; the kb-guard hook refuses it.
   - **Memory is the kb.** Before acting on a project, person or tool, run `claude_kb/kb search <words>` (or `kb ask <question>`) and read what it returns; save anything durable with `kb add`/`kb edit`, never as a file in `memory/` (the memory-guard hook refuses that).
   ```
6. Schedule `kb backup && kb prune` once an hour (cron or a launchd agent). The database is the only copy. `backup` first runs `load` and `embed`, so a memory file that a session still wrote is pulled in; `prune` keeps 48 hourly dumps, then 30 six-hourly, 7 daily, then one per month.

## Variables
`KB_DB` (database name, default `kb`), `KB_MEMDIR` (the Claude Code project folder, default derived from `TEAM_ROOT`), `KB_MODEL`, `KB_OLLAMA`, `TEAM_ROOT`. The two guards read `KB_DB`, `KB_MEMDIR` and `TEAM_ROOT` too.

## Restore
`createdb kb_restored && pigz -dc <backup file> | psql -d kb_restored`, by hand, then compare before you rename anything.
