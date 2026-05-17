-- Recency-weighted edge speeds: exponential decay with 60-day half-life.
--
-- The previous recompute used `avg(speed_ms)` across all observations,
-- which means a beginner-era observation from 2 years ago drags down a
-- current expert's prediction by exactly the same weight as today's run.
-- A skier's ability and pace drift over time; the algorithm should track
-- it.
--
-- Weight = exp(-(now - run_at) / tau) where tau is chosen so that an
-- observation from 60 days ago has half the weight of one from today.
-- Concretely: tau_days = 60 / ln(2) ≈ 86.56 days.
-- weight = exp(-age_days / 86.56)
--
-- Identity-preserving: an observation from this morning still gets ~1.0,
-- a 1-month-old gets ~0.71, a 2-month-old (the half-life) gets 0.5,
-- a 6-month-old gets ~0.13, a 1-year-old gets ~0.015. So very old
-- observations effectively phase out without a hard cutoff.
--
-- Variance column (Welford-style online variance) added in the same
-- migration so the solver can score on distributions, not point
-- estimates: see CLAUDE.md "CVaR scoring" item.

alter table public.profile_edge_speeds
  add column if not exists rolling_speed_variance_ms2 double precision not null default 0;

create or replace function public.recompute_profile_edge_speeds(uid uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- 60-day half-life expressed as the tau coefficient for exp decay.
  tau_days constant double precision := 60.0 / ln(2.0);
begin
  delete from public.profile_edge_speeds where profile_id = uid;
  insert into public.profile_edge_speeds (
    profile_id, resort_id, edge_id, conditions_fp,
    observation_count,
    rolling_speed_ms, rolling_peak_ms, rolling_duration_s,
    rolling_speed_variance_ms2,
    last_observed_at
  )
  with weighted as (
    select
      coalesce(resort_id, 'unknown')               as resort_id,
      edge_id,
      coalesce(conditions_fp, 'default')           as conditions_fp,
      speed_ms,
      coalesce(peak_speed_ms, speed_ms)            as peak_speed_ms,
      duration_s,
      run_at,
      -- Weight = exp(-age_days / tau). Uses now() at recompute time
      -- so the same observation re-weighted later naturally decays
      -- further on every recompute.
      exp(-greatest(0, extract(epoch from (now() - run_at)) / 86400.0) / tau_days) as w
    from public.imported_runs
    where profile_id = uid
      and edge_id is not null
  ),
  agg as (
    select
      resort_id, edge_id, conditions_fp,
      count(*)::int                                              as obs_count,
      sum(speed_ms * w) / nullif(sum(w), 0)                      as weighted_mean_speed,
      sum(power(speed_ms, 2) * w) / nullif(sum(w), 0)            as weighted_mean_sq_speed,
      max(peak_speed_ms)                                         as peak_speed,
      sum(duration_s * w) / nullif(sum(w), 0)                    as weighted_mean_duration,
      max(run_at)                                                as last_seen
    from weighted
    group by resort_id, edge_id, conditions_fp
  )
  select
    uid,
    resort_id, edge_id, conditions_fp,
    obs_count,
    coalesce(weighted_mean_speed, 0)                                          as rolling_speed_ms,
    peak_speed                                                                as rolling_peak_ms,
    coalesce(weighted_mean_duration, 0)                                       as rolling_duration_s,
    -- E[X^2] - (E[X])^2; clamped at 0 to absorb floating-point noise
    -- on edges with a single observation (variance is mathematically
    -- 0 there but can come back as -1e-15).
    greatest(0, coalesce(weighted_mean_sq_speed, 0) - power(coalesce(weighted_mean_speed, 0), 2))
                                                                              as rolling_speed_variance_ms2,
    last_seen
  from agg;
end;
$function$;
