# claude_kb: the team's memory in Postgres (optional)

Claude Code keeps a project's memory as files under `~/.claude/projects/<project>/memory/`. With many sessions writing there, files get duplicated, overwritten and lost. This part of the kit moves memory into one Postgres table that every session reaches the same way, through one script. No script in the kit needs it, and `install.sh` only copies it. But `house_rules.md` ships with the two kb rules, as the team this kit came from runs it: set the kb up (below), or delete those two lines.

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
5. `house_rules.md` already carries the two kb rules, under "Secrets and data" ("Memories live in Postgres…" and "Memory is the kb"). They bind every session, and the review sweeps judge against them. **If you don't run the kb, delete those two lines**, or every session breaks a rule it can't keep.
6. Schedule `kb backup && kb prune` once an hour (cron or a launchd agent). The database is the only copy. `backup` first runs `load` and `embed`, so a memory file that a session still wrote is pulled in; `prune` keeps 48 hourly dumps, then 30 six-hourly, 7 daily, then one per month.

## Variables
`KB_DB` (database name, default `kb`), `KB_MEMDIR` (the Claude Code project folder, default derived from `TEAM_ROOT`), `KB_MODEL`, `KB_OLLAMA`, `TEAM_ROOT`. The two guards read `KB_DB`, `KB_MEMDIR` and `TEAM_ROOT` too.

## Restore
`createdb kb_restored && pigz -dc <backup file> | psql -d kb_restored`, by hand, then compare before you rename anything.
