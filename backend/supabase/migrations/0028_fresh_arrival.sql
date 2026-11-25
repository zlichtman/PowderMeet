-- 0028 An old arrival no longer completes a meet. specs/03-PROTOCOL.md sections 1, 2
-- and 4, specs/04-SCHEMA.md section 11.
--
-- A skier who arrived, lost service and left kept `arrived` stored, so the
-- friend arriving later completed the meet as if they had met. The partner's
-- `arrived` now counts only while its fix is at most 120 s old. A phone that
-- stays at the meeting point keeps that row fresh: the location driver repeats
-- a still phone's position every 45 s and the progress tick sends each new fix.
-- The client holds the same bound (`MeetSession.arrivalFreshS`).

-- ======================================================== meet_progress_update

-- 0025's function. The caller's own row is the fix just sent; the partner's
-- `arrived` counts only with `fix_at` within 120 s of server time.
create or replace function public.meet_progress_update(
  p_meet_id uuid, p_eta_s int, p_eta_sd_s int, p_remaining_m int,
  p_state text, p_fix_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_now timestamptz := clock();
  v_meet meets;
begin
  select m.* into v_meet from meets m where m.meet_id = p_meet_id for update;
  if not found or v_me not in (v_meet.proposer_id, v_meet.invitee_id) then
    raise exception 'not_participant';
  end if;
  if v_meet.status <> 'active' or p_fix_at is null
     or p_state is null or p_state not in ('navigating', 'rerouting', 'arrived', 'lost') then
    raise exception 'invalid_state';
  end if;
  -- A caller writes only their own row.
  insert into meet_progress as mp (meet_id, user_id, eta_s, eta_sd_s, remaining_m, state, fix_at, updated_at)
  values (p_meet_id, v_me, p_eta_s, p_eta_sd_s, p_remaining_m, p_state,
          least(p_fix_at, v_now + interval '1 minute'), v_now)
  on conflict (meet_id, user_id) do update
    set eta_s = excluded.eta_s, eta_sd_s = excluded.eta_sd_s, remaining_m = excluded.remaining_m,
        state = excluded.state, fix_at = excluded.fix_at, updated_at = excluded.updated_at
    where excluded.fix_at >= mp.fix_at or mp.fix_at > v_now + interval '1 minute';

  if (select count(*) from meet_progress mp
      where mp.meet_id = p_meet_id and mp.state = 'arrived'
        and mp.user_id in (v_meet.proposer_id, v_meet.invitee_id)
        and (mp.user_id = v_me or mp.fix_at >= v_now - interval '120 seconds')) = 2 then
    update meets m
    set status = 'completed', end_reason = 'arrived', ended_at = v_now
    where m.meet_id = p_meet_id and m.status = 'active'
    returning m.* into v_meet;
    if found then
      perform push_enqueue(v_meet.proposer_id, 'meet.ended', meet_push_payload(v_meet, v_meet.proposer_id));
      perform push_enqueue(v_meet.invitee_id, 'meet.ended', meet_push_payload(v_meet, v_meet.invitee_id));
    end if;
  end if;
end;
$$;

-- `create or replace` keeps the function's grants, so no execute statement
-- follows.
