-- claude_kb: one table. The DB is the only copy; nothing syncs back to files.
-- All access goes through the kb script (hook kb-guard.sh refuses direct psql).
\set ON_ERROR_STOP 1
create extension if not exists pg_trgm;
create extension if not exists vector;

create table if not exists memory (
  id          bigserial primary key,
  stem        text        not null,               -- the memory's name; the [[link]] target
  type        text        not null,               -- user | feedback | project | reference | hub | note
  body        text        not null,               -- stored as written
  created_at  timestamptz not null default now(),
  current     boolean     not null default true,  -- false once a newer row for the stem exists, or retired
  embedding   vector(1024),                       -- qwen3-embedding:0.6b over body
  tsv         tsvector    generated always as (to_tsvector('english', body)) stored
);
create unique index if not exists memory_current_stem on memory (stem) where current;
create index if not exists memory_tsv       on memory using gin  (tsv);
create index if not exists memory_body_trgm on memory using gin  (body gin_trgm_ops);
create index if not exists memory_stem_trgm on memory using gin  (stem gin_trgm_ops);
create index if not exists memory_embedding on memory using hnsw (embedding vector_cosine_ops);
