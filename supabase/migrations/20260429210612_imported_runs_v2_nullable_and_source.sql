alter table public.imported_runs
  alter column edge_id    drop not null,
  alter column difficulty drop not null,
  add column if not exists source           text,
  add column if not exists source_file_hash text;

create index if not exists imported_runs_profile_dedup_idx
  on public.imported_runs (profile_id, dedup_hash);

create index if not exists imported_runs_profile_source_hash_idx
  on public.imported_runs (profile_id, source_file_hash)
  where source_file_hash is not null;;
