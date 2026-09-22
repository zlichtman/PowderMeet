-- ─────────────────────────────────────────────────────────────────────────────
-- imported_runs: one row per matched run from an activity import.
-- dedup_hash collapses re-imports of the same file into the same row.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.imported_runs (
  id              uuid primary key default uuid_generate_v4(),
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  resort_id       text,
  edge_id         text not null,
  difficulty      text not null,
  speed_ms        double precision not null,
  duration_s      double precision not null,
  vertical_m      double precision not null default 0,
  run_at          timestamptz not null,
  dedup_hash      text not null,
  created_at      timestamptz not null default now(),
  unique (profile_id, dedup_hash)
);

create index if not exists imported_runs_profile_idx
  on public.imported_runs (profile_id, run_at desc);

alter table public.imported_runs enable row level security;

drop policy if exists "imported_runs_select_public"   on public.imported_runs;
drop policy if exists "imported_runs_insert_own"      on public.imported_runs;
drop policy if exists "imported_runs_update_own"      on public.imported_runs;
drop policy if exists "imported_runs_delete_own"      on public.imported_runs;

create policy "imported_runs_select_public"
  on public.imported_runs for select using (true);

create policy "imported_runs_insert_own"
  on public.imported_runs for insert
  to authenticated
  with check (auth.uid() = profile_id);

create policy "imported_runs_update_own"
  on public.imported_runs for update
  to authenticated
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

create policy "imported_runs_delete_own"
  on public.imported_runs for delete
  to authenticated
  using (auth.uid() = profile_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- profile_stats: per-profile aggregate. One row per profile.
-- Recomputed by recompute_profile_stats(uid).
-- Public-readable so friend cards can show their stats too.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.profile_stats (
  profile_id          uuid primary key references public.profiles(id) on delete cascade,
  days_skied          integer not null default 0,
  runs_count          integer not null default 0,
  vertical_m          double precision not null default 0,
  top_speed_ms        double precision not null default 0,
  total_duration_s    double precision not null default 0,
  last_import_at      timestamptz,
  updated_at          timestamptz not null default now()
);

alter table public.profile_stats enable row level security;

drop policy if exists "profile_stats_select_public" on public.profile_stats;
drop policy if exists "profile_stats_upsert_own"    on public.profile_stats;
drop policy if exists "profile_stats_update_own"    on public.profile_stats;

create policy "profile_stats_select_public"
  on public.profile_stats for select using (true);

create policy "profile_stats_upsert_own"
  on public.profile_stats for insert
  to authenticated
  with check (auth.uid() = profile_id);

create policy "profile_stats_update_own"
  on public.profile_stats for update
  to authenticated
  using (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- recompute_profile_stats(uid): aggregate from imported_runs and upsert.
-- security definer so the function can write to the row regardless of which
-- role triggers it (the WITH CHECK above already guards the call site).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recompute_profile_stats(uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profile_stats as ps (
    profile_id, days_skied, runs_count, vertical_m,
    top_speed_ms, total_duration_s, last_import_at, updated_at
  )
  select
    uid,
    coalesce(count(distinct date_trunc('day', run_at)), 0)::int,
    coalesce(count(*), 0)::int,
    coalesce(sum(vertical_m), 0),
    coalesce(max(speed_ms), 0),
    coalesce(sum(duration_s), 0),
    max(run_at),
    now()
  from public.imported_runs
  where profile_id = uid
  on conflict (profile_id) do update set
    days_skied        = excluded.days_skied,
    runs_count        = excluded.runs_count,
    vertical_m        = excluded.vertical_m,
    top_speed_ms      = excluded.top_speed_ms,
    total_duration_s  = excluded.total_duration_s,
    last_import_at    = excluded.last_import_at,
    updated_at        = now();
end;
$$;

revoke all on function public.recompute_profile_stats(uuid) from public;
grant execute on function public.recompute_profile_stats(uuid) to authenticated;;
