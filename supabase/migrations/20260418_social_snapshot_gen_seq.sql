-- Strictly monotonic snapshot generations for get_social_snapshot.
--
-- Wall-clock nanoseconds can collide when multiple RPCs finish in the same
-- tick; the Swift client discards snapshots with generation <=
-- lastServerGeneration, so a duplicate stamp could drop a legitimate friends-list update (add/remove friend) and leave friendIdsProvider stale.

create sequence if not exists public.social_snapshot_generation_seq;

create or replace function public.get_social_snapshot(p_resort_id text default null)
returns jsonb
language plpgsql
security invoker
volatile
set search_path = public
as $$
declare
  uid uuid := (select auth.uid());
  friend_ids uuid[];
  friends_json jsonb;
  pending_recv_json jsonb;
  pending_sent_json jsonb;
  presence_json jsonb;
  gen bigint;
begin
  if uid is null then
    return jsonb_build_object(
      'generation', 0,
      'friends', '[]'::jsonb,
      'pending_received', '[]'::jsonb,
      'pending_sent', '[]'::jsonb,
      'presence', null
    );
  end if;

  select coalesce(array_agg(
    case when f.requester_id = uid then f.addressee_id else f.requester_id end
  ), array[]::uuid[])
    into friend_ids
    from public.friendships f
   where f.status = 'accepted'
     and (f.requester_id = uid or f.addressee_id = uid);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',                 p.id,
           'display_name',       p.display_name,
           'avatar_url',         p.avatar_url,
           'skill_level',        p.skill_level,
           'current_resort_id',  p.current_resort_id
         )), '[]'::jsonb)
    into friends_json
    from public.profiles p
   where p.id = any(friend_ids);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            f.id,
           'requester_id',  f.requester_id,
           'addressee_id',  f.addressee_id,
           'status',        f.status,
           'created_at',    f.created_at
         )), '[]'::jsonb)
    into pending_recv_json
    from public.friendships f
   where f.status = 'pending'
     and f.addressee_id = uid
     and not (f.requester_id = any(friend_ids));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            f.id,
           'requester_id',  f.requester_id,
           'addressee_id',  f.addressee_id,
           'status',        f.status,
           'created_at',    f.created_at
         )), '[]'::jsonb)
    into pending_sent_json
    from public.friendships f
   where f.status = 'pending'
     and f.requester_id = uid
     and not (f.addressee_id = any(friend_ids));

  if p_resort_id is not null then
    select coalesce(jsonb_object_agg(
             lp.user_id::text,
             jsonb_build_object(
               'user_id',     lp.user_id,
               'resort_id',   lp.resort_id,
               'lat',         lp.lat,
               'lon',         lp.lon,
               'captured_at', lp.captured_at,
               'accuracy_m',  lp.accuracy_m,
               'last_seen',   lp.last_seen
             )
           ), '{}'::jsonb)
      into presence_json
      from public.live_presence lp
     where lp.resort_id = p_resort_id
       and lp.user_id = any(friend_ids)
       and lp.last_seen >= (now() - interval '15 minutes');
  else
    presence_json := null;
  end if;

  gen := nextval('public.social_snapshot_generation_seq');

  return jsonb_build_object(
    'generation',       gen,
    'friends',          friends_json,
    'pending_received', pending_recv_json,
    'pending_sent',     pending_sent_json,
    'presence',         presence_json
  );
end;
$$;

grant execute on function public.get_social_snapshot(text) to authenticated;
