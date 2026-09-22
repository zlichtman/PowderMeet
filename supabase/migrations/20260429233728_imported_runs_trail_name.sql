alter table public.imported_runs
  add column if not exists trail_name text;;
